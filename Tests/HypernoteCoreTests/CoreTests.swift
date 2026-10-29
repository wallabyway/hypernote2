import XCTest
@testable import HypernoteCore

final class ParsingTests: XCTestCase {
    func testParsesDiarizedUtterances() throws {
        let json = """
        {"status":"completed","audio_duration":42,"text":"hi there",
         "utterances":[
           {"speaker":"A","text":"Hello team","start":0,"end":1500},
           {"speaker":"B","text":"Morning","start":1600,"end":2200},
           {"speaker":"A","text":"","start":2300,"end":2400}
         ]}
        """.data(using: .utf8)!
        let result = try AssemblyAIClient.parseTranscript(json)
        XCTAssertEqual(result.durationSec, 42)
        XCTAssertEqual(result.utterances, [
            Utterance(speaker: "A", text: "Hello team", startMs: 0, endMs: 1500),
            Utterance(speaker: "B", text: "Morning", startMs: 1600, endMs: 2200),
        ])
    }

    func testFallsBackToPlainTextWithoutUtterances() throws {
        let json = #"{"status":"completed","audio_duration":3,"text":"just me talking","utterances":null}"#
            .data(using: .utf8)!
        let result = try AssemblyAIClient.parseTranscript(json)
        XCTAssertEqual(result.utterances.count, 1)
        XCTAssertEqual(result.utterances[0].speaker, "A")
        XCTAssertEqual(result.utterances[0].endMs, 3000)
    }

    func testEmptyTranscript() throws {
        let result = try AssemblyAIClient.parseTranscript(#"{"status":"completed","text":""}"#.data(using: .utf8)!)
        XCTAssertTrue(result.utterances.isEmpty)
    }

    func testPickFlashModelPrefersDocumentedId() {
        XCTAssertEqual(DeepSeekClient.pickFlashModel(from: ["deepseek-v4-pro", "deepseek-flash"]), "deepseek-flash")
        XCTAssertEqual(DeepSeekClient.pickFlashModel(from: ["deepseek-v4-pro", "deepseek-v4-flash"]), "deepseek-v4-flash")
        XCTAssertEqual(DeepSeekClient.pickFlashModel(from: ["x-Flash-2"]), "x-Flash-2")
        XCTAssertEqual(DeepSeekClient.pickFlashModel(from: []), "deepseek-flash")
    }

    func testParseSSELine() {
        XCTAssertEqual(DeepSeekClient.parseSSELine(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#), "Hi")
        XCTAssertNil(DeepSeekClient.parseSSELine(#"data: {"choices":[{"delta":{"content":""}}]}"#))
        XCTAssertNil(DeepSeekClient.parseSSELine("data: [DONE]"))
        XCTAssertNil(DeepSeekClient.parseSSELine(": keep-alive"))
    }
}

final class PromptTests: XCTestCase {
    private func sample() -> Session {
        var s = Session(id: "s1", templateId: "daily-standup")
        s.title = "Standup"
        s.notes = "ship friday"
        s.utterances = [
            Utterance(speaker: "A", text: "I finished the API.", startMs: 0, endMs: 2000),
            Utterance(speaker: "B", text: "Blocked on review.", startMs: 65_000, endMs: 67_000),
        ]
        s.speakerNames = ["A": "Maya"]
        return s
    }

    func testTranscriptUsesRenamedAndDefaultSpeakers() {
        let text = Prompts.transcriptText(for: sample())
        XCTAssertEqual(text, "[00:00] Maya: I finished the API.\n[01:05] Speaker B: Blocked on review.")
    }

    func testTimestampFormatting() {
        XCTAssertEqual(Prompts.timestamp(ms: 3_725_000), "1:02:05")
        XCTAssertEqual(Prompts.timestamp(ms: -5), "00:00")
    }

    func testSummaryMessagesContainTemplateNotesAndTranscript() {
        let msgs = Prompts.summaryMessages(session: sample(), template: BuiltInTemplates.dailyStandup)
        for section in BuiltInTemplates.dailyStandup.sections {
            XCTAssertTrue(msgs.user.contains(section.title), section.title)
        }
        XCTAssertTrue(msgs.user.contains("ship friday"))
        XCTAssertTrue(msgs.user.contains("Maya: I finished the API."))
        XCTAssertTrue(msgs.system.contains("## Title"))
    }

    func testGeneralTemplateAsksForDiagramAndActionTable() {
        let titles = BuiltInTemplates.general.sections.map(\.title)
        XCTAssertEqual(titles, ["Overview", "Visual Summary", "Key Points", "Decisions", "Action Items"])
        XCTAssertTrue(BuiltInTemplates.general.sections[1].description.contains("Mermaid"))
        XCTAssertTrue(BuiltInTemplates.general.sections[4].description.contains("Owner | Task | Due"))
        XCTAssertTrue(Prompts.systemPrompt.contains("```mermaid"))
        XCTAssertTrue(Prompts.systemPrompt.contains("fa:fa-check"))
    }

    func testBuiltInTemplatesCoverRequestedMeetingTypes() {
        let ids = Set(BuiltInTemplates.all.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["one-on-one", "brainstorming", "daily-standup", "customer-demo"]))
        XCTAssertEqual(ids.count, BuiltInTemplates.all.count)
        XCTAssertTrue(BuiltInTemplates.all.allSatisfy { !$0.sections.isEmpty })
    }
}

final class AudioTests: XCTestCase {
    func testMixPadsShortSourceAndClamps() {
        let out = AudioMixer.mix([0.5, 0.9, 0.9], [0.4], count: 4)
        XCTAssertEqual(out, [0.9, 0.9, 0.9, 0.0])
    }

    func testRMS() {
        XCTAssertEqual(AudioMixer.rms([]), 0)
        XCTAssertEqual(AudioMixer.rms([1, -1, 1, -1]), 1, accuracy: 1e-6)
    }

    func testSampleQueueTakeAndTrim() {
        let q = SampleQueue()
        q.append([1, 2, 3, 4, 5])
        XCTAssertEqual(q.take(2), [1, 2])
        q.trim(keep: 2)
        XCTAssertEqual(q.take(10), [4, 5])
        XCTAssertEqual(q.count, 0)
    }
}

final class StoreTests: XCTestCase {
    func testRoundTripAndOrdering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(root: dir)

        var older = Session(id: "old", templateId: "general", now: Date(timeIntervalSince1970: 1_000))
        older.summary = "## Overview\nhello"
        let newer = Session(id: "new", templateId: "general", now: Date(timeIntervalSince1970: 2_000))
        try store.save(older)
        try store.save(newer)

        XCTAssertEqual(store.listSessions().map(\.id), ["new", "old"])
        XCTAssertEqual(store.loadSession("old")?.summary, "## Overview\nhello")
        store.deleteSession("old")
        XCTAssertNil(store.loadSession("old"))
    }

    func testCustomTemplatesAppendToBuiltIns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(root: dir)
        let custom = MeetingTemplate(id: "custom-1", title: "Retro", description: "", icon: "🔁",
                                     sections: [.init(title: "Went well", description: "")])
        try store.saveCustomTemplates([custom])
        XCTAssertEqual(store.allTemplates().count, BuiltInTemplates.all.count + 1)
        XCTAssertEqual(store.allTemplates().last?.id, "custom-1")
    }
}
