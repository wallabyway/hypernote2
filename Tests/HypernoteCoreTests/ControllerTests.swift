import XCTest
@testable import HypernoteCore

/// Routes requests by path to canned responses so the controller runs fully offline.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.handler?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ControllerTests: XCTestCase {
    private var dir: URL!
    private var controller: AppController!
    private var secrets: InMemorySecretStore!
    private var events: [(String, [String: Any])] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        secrets = InMemorySecretStore()
        controller = AppController(store: Store(root: dir), secrets: secrets, urlSession: URLSession(configuration: config),
                                   obsidianConfig: dir.appendingPathComponent("obsidian.json"))
        events = []
        controller.onEvent = { [unowned self] name, payload in events.append((name, payload)) }
        StubProtocol.requests = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        StubProtocol.handler = nil
    }

    private func sse(_ pieces: [String]) -> Data {
        let lines = pieces.map { #"data: {"choices":[{"delta":{"content":"\#($0)"}}]}"# + "\n\n" }
        return (lines.joined() + "data: [DONE]\n\n").data(using: .utf8)!
    }

    func testSaveKeysVerifiesBothProvidersAndPicksFlashModel() async throws {
        StubProtocol.handler = { req in
            switch req.url!.host! {
            case "api.assemblyai.com": return (200, #"{"transcripts":[]}"#.data(using: .utf8)!)
            case "api.deepseek.com": return (200, #"{"data":[{"id":"deepseek-v4-pro"},{"id":"deepseek-flash"}]}"#.data(using: .utf8)!)
            default: return (404, Data())
            }
        }
        let state = try await controller.handle(command: "saveKeys",
                                                args: ["assemblyai": " aai-key ", "deepseek": "ds-key"]) as! [String: Any]
        XCTAssertEqual(state["hasAssemblyKey"] as? Bool, true)
        XCTAssertEqual(state["hasDeepseekKey"] as? Bool, true)
        XCTAssertEqual(secrets.get("assemblyai"), "aai-key")
        XCTAssertEqual(secrets.get("deepseek"), "ds-key")
        let aai = StubProtocol.requests.first { $0.url?.host == "api.assemblyai.com" }
        XCTAssertEqual(aai?.value(forHTTPHeaderField: "authorization"), "aai-key")
        let ds = StubProtocol.requests.first { $0.url?.host == "api.deepseek.com" }
        XCTAssertEqual(ds?.value(forHTTPHeaderField: "Authorization"), "Bearer ds-key")
    }

    func testRejectedKeyIsNotStored() async {
        StubProtocol.handler = { _ in (401, #"{"error":"Authentication error"}"#.data(using: .utf8)!) }
        do {
            _ = try await controller.handle(command: "saveKeys", args: ["assemblyai": "bad"])
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AssemblyAI key rejected"))
        }
        XCTAssertNil(secrets.get("assemblyai"))
    }

    func testSummarizeStreamsDeltasSavesSummaryAndTitlesNote() async throws {
        try secrets.set("ds-key", for: "deepseek")
        var s = Session(id: "n1", templateId: "general")
        s.utterances = [Utterance(speaker: "A", text: "We ship Friday.", startMs: 0, endMs: 1000)]
        try controller.store.save(s)

        var sawStreamingRequest = false
        StubProtocol.handler = { req in
            let body = (req.httpBody ?? req.httpBodyStream.flatMap { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
                return data
            }) ?? Data()
            let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if obj?["stream"] as? Bool == true {
                sawStreamingRequest = true
                XCTAssertEqual((obj?["thinking"] as? [String: Any])?["type"] as? String, "disabled")
                return (200, self.sse(["## Overview\\n", "Ship Friday."]))
            }
            return (200, #"{"choices":[{"message":{"content":"\"Friday Ship Plan\""}}]}"#.data(using: .utf8)!)
        }

        _ = try await controller.handle(command: "summarize", args: ["id": "n1", "templateId": "brainstorming"])
        try await waitUntil { self.controller.store.loadSession("n1")?.title == "Friday Ship Plan" }

        let saved = controller.store.loadSession("n1")!
        XCTAssertTrue(sawStreamingRequest)
        XCTAssertEqual(saved.status, .done)
        XCTAssertEqual(saved.summary, "## Overview\nShip Friday.")
        XCTAssertEqual(saved.summaryTemplateId, "brainstorming")
        XCTAssertEqual(events.filter { $0.0 == "summary_delta" }.count, 2)
    }

    func testSummarizeWithNothingToSummarizeFailsCleanly() async throws {
        try secrets.set("ds-key", for: "deepseek")
        try controller.store.save(Session(id: "empty", templateId: "general"))
        _ = try await controller.handle(command: "summarize", args: ["id": "empty"])
        try await waitUntil { self.controller.store.loadSession("empty")?.status == .error }
        XCTAssertTrue(controller.store.loadSession("empty")!.error!.contains("Nothing to summarize"))
    }

    func testCustomTemplateLifecycleAndBuiltInProtection() async throws {
        let saved = try await controller.handle(command: "saveTemplate", args: ["template": [
            "id": "", "title": "Retro", "description": "Team retro", "icon": "",
            "sections": [["title": "Went well", "description": "wins"]],
        ]]) as! [[String: Any]]
        let custom = saved.first { ($0["builtIn"] as? Bool) == false }!
        XCTAssertEqual(custom["title"] as? String, "Retro")
        XCTAssertTrue((custom["id"] as! String).hasPrefix("custom-"))

        do {
            _ = try await controller.handle(command: "saveTemplate", args: ["template": [
                "id": "general", "title": "Hacked", "description": "", "icon": "x", "sections": [],
            ]])
            XCTFail("built-ins must be read-only")
        } catch {}

        let after = try await controller.handle(command: "deleteTemplate", args: ["id": custom["id"]!]) as! [[String: Any]]
        XCTAssertEqual(after.count, BuiltInTemplates.all.count)
    }

    func testStartRecordingRequiresKeys() async {
        let s = try! await controller.handle(command: "createSession", args: [:]) as! [String: Any]
        do {
            _ = try await controller.handle(command: "startRecording", args: ["id": s["id"]!])
            XCTFail("expected missing key error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AssemblyAI"))
        }
    }

    func testExportSummaryWritesMarkdownIntoObsidianVault() async throws {
        // Two vaults; the open one wins.
        let fm = FileManager.default
        let open = dir.appendingPathComponent("Work Vault"), other = dir.appendingPathComponent("Old")
        for v in [open, other] { try fm.createDirectory(at: v.appendingPathComponent(".obsidian"), withIntermediateDirectories: true) }
        let config = ["vaults": ["a": ["path": other.path, "ts": 999], "b": ["path": open.path, "ts": 1, "open": true]]]
        try JSONSerialization.data(withJSONObject: config).write(to: dir.appendingPathComponent("obsidian.json"))

        var s = Session(id: "x", templateId: "daily-standup", now: Date(timeIntervalSince1970: 1_761_600_000))
        s.title = "Standup: API / pricing"
        s.summary = "## Action Items\n- Raj: review"
        s.notes = "ping legal"
        s.durationSec = 600
        s.utterances = [Utterance(speaker: "A", text: "hi", startMs: 0, endMs: 1), Utterance(speaker: "B", text: "yo", startMs: 1, endMs: 2)]
        s.speakerNames = ["A": "Maya"]
        try controller.store.save(s)

        let state = try await controller.handle(command: "state", args: [:]) as! [String: Any]
        let export = state["export"] as! [String: Any]
        XCTAssertEqual(export["folder"] as? String, open.appendingPathComponent("Meetings").path)
        XCTAssertEqual(export["vault"] as? String, "Work Vault")

        let r = try await controller.handle(command: "exportSummary", args: ["id": "x"]) as! [String: Any]
        let text = try String(contentsOfFile: r["path"] as! String, encoding: .utf8)
        XCTAssertTrue((r["name"] as! String).hasSuffix("Standup API pricing.md"), r["name"] as! String)
        XCTAssertTrue(text.hasPrefix("---\ntitle: \"Standup: API / pricing\""))
        XCTAssertTrue(text.contains("speakers: [\"Maya\", \"Speaker B\"]"))
        XCTAssertTrue(text.contains("template: \"Daily Standup\""))
        XCTAssertTrue(text.contains("# Standup: API / pricing\n\n## Action Items\n- Raj: review\n"))
        XCTAssertTrue(text.contains("## My Notes\n\nping legal"))

        // A custom folder overrides the vault default; reset restores it.
        let custom = dir.appendingPathComponent("elsewhere")
        _ = try await controller.handle(command: "setSettings", args: ["exportFolder": custom.path])
        _ = try await controller.handle(command: "exportSummary", args: ["id": "x"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: custom.path).count, 1)
        let reset = try await controller.handle(command: "setSettings", args: ["resetExportFolder": true]) as! [String: Any]
        XCTAssertEqual((reset["export"] as! [String: Any])["isCustom"] as? Bool, false)
    }

    func testExportWithoutSummaryFails() async throws {
        try controller.store.save(Session(id: "e", templateId: "general"))
        do { _ = try await controller.handle(command: "exportSummary", args: ["id": "e"]); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("no summary")) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
