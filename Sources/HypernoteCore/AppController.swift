import AppKit
import Foundation

/// Owns app state and executes every command the web UI can send.
@MainActor
public final class AppController {
    public var onEvent: ((String, [String: Any]) -> Void)?
    public var onRecordingChange: ((Bool) -> Void)?
    public private(set) var recordingSessionId: String?
    public var isRecording: Bool { recordingSessionId != nil }
    public private(set) var isPaused = false
    public private(set) var isAutoPaused = false
    /// Called whenever recording starts/stops or pauses/resumes.
    public var onPauseChange: ((Bool) -> Void)?

    let store: Store
    let secrets: SecretStore
    let urlSession: URLSession
    let obsidianConfig: URL
    private var recorder: MeetingRecorder?
    private var recordingStart: Date?
    private var tickTimer: Timer?
    private var pipelines: [String: Task<Void, Never>] = [:]
    /// True while `startRecording` is awaiting the recorder, so a double click can't start two recorders.
    private var isStarting = false
    private var isStopping = false
    private var autoPausedAt: Date?
    public private(set) var microphoneOK = true
    let playback = AudioPlayback()

    /// After this long auto-paused (e.g. the meeting ended but nobody pressed Stop), the recording
    /// is stopped and processed instead of waiting indefinitely.
    public static let autoStopAfterSilenceSeconds: Double = 15 * 60

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public init(store: Store = Store(), secrets: SecretStore = KeychainSecretStore(),
                urlSession: URLSession = .shared, obsidianConfig: URL = ObsidianVaults.configURL) {
        self.store = store
        self.secrets = secrets
        self.urlSession = urlSession
        self.obsidianConfig = obsidianConfig
        playback.onUpdate = { [weak self] state in self?.emit("playback", state) }
        recoverInterruptedSessions()
    }

    // MARK: Command dispatch

    public func handle(command: String, args: [String: Any]) async throws -> Any {
        switch command {
        case "state":
            return state()
        case "saveKeys":
            try await saveKeys(assembly: args["assemblyai"] as? String, deepseek: args["deepseek"] as? String)
            return state()
        case "setSettings":
            var s = store.loadSettings()
            if let v = args["captureSystemAudio"] as? Bool { s.captureSystemAudio = v }
            if let v = args["autoPause"] as? Bool { s.autoPause = v }
            if let v = args["defaultTemplateId"] as? String { s.defaultTemplateId = v }
            if args["resetExportFolder"] as? Bool == true { s.exportFolder = nil }
            if let v = args["exportFolder"] as? String {
                let path = (v.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
                s.exportFolder = path.isEmpty ? nil : path
            }
            try store.save(s)
            return state()
        case "listSessions":
            return try json(store.listSessions().map(SessionListItem.init))
        case "getSession":
            return try json(try requireSession(args))
        case "createSession":
            var s = Session(templateId: store.loadSettings().defaultTemplateId)
            if let t = args["templateId"] as? String { s.templateId = t }
            try store.save(s)
            return try json(s)
        case "updateSession":
            return try updateSession(args)
        case "deleteSession":
            let id = try requireId(args)
            guard id != recordingSessionId else { throw HypernoteError.message("Stop the recording first.") }
            if playback.sessionId == id { playback.stop() }
            pipelines[id]?.cancel()
            pipelines[id] = nil
            store.deleteSession(id)
            return NSNull()
        case "startRecording":
            try await startRecording(id: try requireId(args))
            return state()
        case "stopRecording":
            await stopRecording()
            return NSNull()
        case "pauseRecording":
            pauseRecording()
            return NSNull()
        case "resumeRecording":
            resumeRecording()
            return NSNull()
        case "playAudio":
            let id = try requireId(args)
            guard !isRecording else { throw HypernoteError.message("Playback is off while recording, so it doesn't end up in the recording.") }
            let url = store.audioURL(for: id)
            guard FileManager.default.fileExists(atPath: url.path) else { throw HypernoteError.message("This note has no audio.") }
            do { try playback.play(id: id, url: url, at: (args["at"] as? NSNumber)?.doubleValue) }
            catch { throw HypernoteError.message("Couldn't play the recording: \(describe(error))") }
            return playback.state()
        case "pauseAudio":
            playback.pause()
            return playback.state()
        case "seekAudio":
            if let at = (args["at"] as? NSNumber)?.doubleValue { playback.seek(to: at) }
            return playback.state()
        case "stopAudio":
            playback.stop()
            return NSNull()
        case "summarize":
            let id = try requireId(args)
            startSummary(id: id, templateId: args["templateId"] as? String)
            return NSNull()
        case "retry":
            retry(id: try requireId(args))
            return NSNull()
        case "saveTemplate":
            try saveTemplate(args)
            return try json(store.allTemplates())
        case "deleteTemplate":
            let id = try requireId(args)
            try store.saveCustomTemplates(store.loadCustomTemplates().filter { $0.id != id })
            return try json(store.allTemplates())
        case "exportSummary":
            return try exportSummary(try requireSession(args))
        case "chooseExportFolder":
            if let path = await chooseFolder(start: exportFolder()) {
                var s = store.loadSettings()
                s.exportFolder = path
                try store.save(s)
            }
            return state()
        case "revealExportFolder":
            let folder = exportFolder()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            return NSNull()
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(args["text"] as? String ?? "", forType: .string)
            return NSNull()
        case "revealAudio":
            let url = store.audioURL(for: try requireId(args))
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return NSNull()
        case "openURL":
            if let s = args["url"] as? String, let url = URL(string: s), url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return NSNull()
        default:
            throw HypernoteError.message("Unknown command: \(command)")
        }
    }

    // MARK: State

    private func state() -> [String: Any] {
        [
            "hasAssemblyKey": secrets.get("assemblyai") != nil,
            "hasDeepseekKey": secrets.get("deepseek") != nil,
            "settings": (try? json(store.loadSettings())) ?? NSNull(),
            "templates": (try? json(store.allTemplates())) ?? [],
            "recordingSessionId": recordingSessionId ?? NSNull(),
            "recordingPaused": isPaused,
            "recordingAutoPaused": isAutoPaused,
            "microphoneOK": microphoneOK,
            "playback": playback.state(),
            "recordedSeconds": recorder?.recordedSeconds ?? 0,
            "export": exportInfo(),
        ]
    }

    // MARK: Markdown export (Obsidian)

    /// The folder "Save to Obsidian" writes to: the user's choice, else `<Obsidian vault>/Meetings`.
    func exportFolder() -> URL {
        if let custom = store.loadSettings().exportFolder, !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return ObsidianVaults.defaultFolder(configURL: obsidianConfig)
    }

    private func exportInfo() -> [String: Any] {
        let folder = exportFolder()
        return [
            "folder": folder.path,
            "isCustom": store.loadSettings().exportFolder != nil,
            "vault": ObsidianVaults.vaultName(containing: folder) ?? NSNull(),
            "detectedVault": ObsidianVaults.preferredVault(configURL: obsidianConfig)?.lastPathComponent ?? NSNull(),
        ]
    }

    private func exportSummary(_ session: Session) throws -> [String: Any] {
        guard !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HypernoteError.message("There's no summary to save yet.")
        }
        let template = store.allTemplates().first { $0.id == (session.summaryTemplateId ?? session.templateId) }
        let folder = exportFolder()
        let url: URL
        do { url = try MarkdownExport.write(session: session, template: template, to: folder) }
        catch { throw HypernoteError.message("Couldn't save to \(folder.path): \(describe(error))") }
        return ["path": url.path, "name": url.lastPathComponent,
                "vault": ObsidianVaults.vaultName(containing: folder) ?? NSNull()]
    }

    private func chooseFolder(start: URL) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where Hypernote2 saves Markdown summaries (e.g. a folder in your Obsidian vault)."
        var dir = start
        while !FileManager.default.fileExists(atPath: dir.path) && dir.path != "/" { dir.deleteLastPathComponent() }
        panel.directoryURL = dir
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { cont in panel.begin { cont.resume(returning: $0) } }
        return response == .OK ? panel.url?.path : nil
    }

    private func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: Self.encoder.encode(value), options: [.fragmentsAllowed])
    }

    private func requireId(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? String, !id.isEmpty else { throw HypernoteError.message("Missing id.") }
        return id
    }

    private func requireSession(_ args: [String: Any]) throws -> Session {
        let id = try requireId(args)
        guard let s = store.loadSession(id) else { throw HypernoteError.message("Note not found.") }
        return s
    }

    private func emit(_ name: String, _ payload: [String: Any] = [:]) { onEvent?(name, payload) }

    @discardableResult
    private func update(_ id: String, _ change: (inout Session) -> Void) -> Session? {
        guard var s = store.loadSession(id) else { return nil }
        change(&s)
        s.updatedAt = Date()
        try? store.save(s)
        return s
    }

    private func recoverInterruptedSessions() {
        for s in store.listSessions()
        where [.recording, .uploading, .transcribing, .summarizing].contains(s.status) {
            update(s.id) {
                $0.status = .error
                $0.error = "Hypernote2 was closed before this note finished processing."
                $0.hasAudio = FileManager.default.fileExists(atPath: store.audioURL(for: s.id).path)
            }
        }
    }

    // MARK: Keys

    private func saveKeys(assembly: String?, deepseek: String?) async throws {
        if let key = assembly?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            do { try await AssemblyAIClient(apiKey: key, session: urlSession).verify() }
            catch { throw HypernoteError.message("AssemblyAI key rejected — \(describe(error))") }
            try secrets.set(key, for: "assemblyai")
        }
        if let key = deepseek?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            let model: String
            do { model = try await DeepSeekClient(apiKey: key, session: urlSession).verifyAndPickModel() }
            catch { throw HypernoteError.message("DeepSeek key rejected — \(describe(error))") }
            try secrets.set(key, for: "deepseek")
            var s = store.loadSettings()
            s.deepseekModel = model
            try store.save(s)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Sessions & templates

    private func updateSession(_ args: [String: Any]) throws -> Any {
        let id = try requireId(args)
        guard let s = update(id, { s in
            if let v = args["title"] as? String { s.title = v }
            if let v = args["notes"] as? String { s.notes = v }
            if let v = args["templateId"] as? String { s.templateId = v }
            if let v = args["speakerNames"] as? [String: String] { s.speakerNames = v }
        }) else { throw HypernoteError.message("Note not found.") }
        return try json(s)
    }

    private func saveTemplate(_ args: [String: Any]) throws {
        guard let raw = args["template"] as? [String: Any] else { throw HypernoteError.message("Missing template.") }
        var dict = raw
        dict["builtIn"] = false
        dict["icon"] = (raw["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "📋"
        let existingId = raw["id"] as? String ?? ""
        dict["id"] = existingId.isEmpty ? "custom-\(UUID().uuidString.prefix(8))" : existingId
        let t = try JSONDecoder().decode(MeetingTemplate.self, from: JSONSerialization.data(withJSONObject: dict))
        guard !t.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HypernoteError.message("Give the template a name.")
        }
        guard !BuiltInTemplates.all.contains(where: { $0.id == t.id }) else {
            throw HypernoteError.message("Built-in templates can't be edited — duplicate it first.")
        }
        var custom = store.loadCustomTemplates()
        if let i = custom.firstIndex(where: { $0.id == t.id }) { custom[i] = t } else { custom.append(t) }
        try store.saveCustomTemplates(custom)
    }

    // MARK: Recording

    private func startRecording(id: String) async throws {
        guard !isRecording, !isStarting, !isStopping else {
            throw HypernoteError.message("Already recording another note.")
        }
        guard secrets.get("assemblyai") != nil else { throw HypernoteError.missingKey("AssemblyAI") }
        guard secrets.get("deepseek") != nil else { throw HypernoteError.missingKey("DeepSeek") }
        guard let existing = store.loadSession(id) else { throw HypernoteError.message("Note not found.") }
        if existing.hasAudio {
            throw HypernoteError.message("This note already has a recording. Start a new note to record again.")
        }
        isStarting = true
        defer { isStarting = false }
        playback.stop()   // don't record our own playback

        let settings = store.loadSettings()
        let recorder = MeetingRecorder(autoPause: settings.autoPause)
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.emit("level", ["value": Double(value)]) }
        }
        recorder.onPauseChange = { [weak self] paused, auto in
            Task { @MainActor in self?.setPaused(paused, auto: auto) }
        }
        recorder.onMicrophoneHealth = { [weak self] ok in
            Task { @MainActor in self?.setMicrophoneHealth(ok) }
        }
        try await recorder.start(to: store.audioURL(for: id),
                                 captureSystemAudio: settings.captureSystemAudio)
        self.recorder = recorder
        recordingSessionId = id
        recordingStart = Date()
        microphoneOK = true
        autoPausedAt = nil
        update(id) { $0.status = .recording; $0.error = nil }
        onRecordingChange?(true)
        emit("session", ["id": id])

        if settings.captureSystemAudio && !recorder.systemAudioActive {
            switch recorder.systemAudioProblem {
            case .permissionDenied:
                emit("toast", ["kind": "warning", "message":
                    "Recording your microphone only. To capture the other side of calls, turn on Hypernote2 under System Settings → Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then start a new recording."])
                NSWorkspace.shared.open(SystemAudioPermission.settingsURL)
            case .failed(let reason):
                emit("toast", ["kind": "warning", "message": "Recording your microphone only. \(reason)"])
            case nil:
                break
            }
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)   // keep ticking while a menu is open
        tickTimer = timer
    }

    private func tick() {
        guard let recorder else { return }
        // Recorded time, not wall-clock time, so the clock stops while paused.
        emit("tick", ["seconds": recorder.recordedSeconds])
        // Forgotten recording: the meeting ended, everyone left, nobody pressed Stop.
        if isAutoPaused, let since = autoPausedAt,
           Date().timeIntervalSince(since) >= Self.autoStopAfterSilenceSeconds {
            emit("toast", ["kind": "info", "message":
                "Stopped recording after \(Int(Self.autoStopAfterSilenceSeconds / 60)) minutes of silence. Transcribing what was recorded."])
            Task { await self.stopRecording() }
        }
    }

    public func stopRecording() async {
        guard !isStopping, let id = recordingSessionId, let recorder else { return }
        // Clear state before awaiting so a second Stop (menu bar + window) can't run this twice.
        isStopping = true
        defer { isStopping = false }
        tickTimer?.invalidate()
        tickTimer = nil
        self.recorder = nil
        recordingSessionId = nil
        recordingStart = nil
        isPaused = false
        isAutoPaused = false
        autoPausedAt = nil
        microphoneOK = true
        let duration = await recorder.stop()
        onRecordingChange?(false)
        onPauseChange?(false)

        if duration < 1 {
            update(id) { $0.status = .idle; $0.hasAudio = false }
            try? FileManager.default.removeItem(at: store.audioURL(for: id))
            emit("session", ["id": id])
            emit("toast", ["kind": "warning", "message": "Recording was too short to transcribe."])
            return
        }
        update(id) { $0.durationSec = duration; $0.hasAudio = true; $0.status = .uploading }
        emit("session", ["id": id])
        runPipeline(id: id)
    }

    public func pauseRecording() { recorder?.pause() }
    public func resumeRecording() { recorder?.resume() }

    public func togglePause() {
        if isPaused { resumeRecording() } else { pauseRecording() }
    }

    private func setPaused(_ paused: Bool, auto: Bool) {
        guard recorder != nil, let id = recordingSessionId else { return }
        isPaused = paused
        isAutoPaused = paused && auto
        autoPausedAt = isAutoPaused ? (autoPausedAt ?? Date()) : nil
        onPauseChange?(paused)
        emit("paused", ["id": id, "paused": paused, "auto": auto])
        if paused && auto {
            emit("toast", ["kind": "info", "message":
                "No one has spoken for \(Int(MeetingRecorder.autoPauseSeconds)) seconds, so recording is paused. It resumes when someone talks."])
        }
    }

    private func setMicrophoneHealth(_ ok: Bool) {
        guard recorder != nil, let id = recordingSessionId, ok != microphoneOK else { return }
        microphoneOK = ok
        emit("micStatus", ["id": id, "ok": ok])
        emit("toast", ok
            ? ["kind": "success", "message": "Microphone reconnected. Recording continues."]
            : ["kind": "warning", "message": "The microphone stopped (audio device changed). Reconnecting… System audio is still being recorded."])
    }

    /// Menu-bar shortcut: stop if recording, otherwise start a brand-new note.
    public func toggleRecordingFromMenu() async {
        if isRecording { await stopRecording(); return }
        do {
            let s = Session(templateId: store.loadSettings().defaultTemplateId)
            try store.save(s)
            try await startRecording(id: s.id)
            emit("navigate", ["id": s.id])
        } catch {
            emit("toast", ["kind": "error", "message": describe(error)])
        }
    }

    // MARK: Pipeline (upload → transcribe → summarize)

    private func runPipeline(id: String) {
        pipelines[id]?.cancel()
        pipelines[id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = self.secrets.get("assemblyai") else { throw HypernoteError.missingKey("AssemblyAI") }
                let client = AssemblyAIClient(apiKey: key, session: self.urlSession)

                self.setStatus(id, .uploading)
                let uploadURL = try await client.upload(fileURL: self.store.audioURL(for: id))
                try Task.checkCancellation()

                self.setStatus(id, .transcribing)
                let transcriptId = try await client.createTranscript(audioURL: uploadURL)
                let result = try await client.waitForTranscript(id: transcriptId)
                self.update(id) {
                    $0.utterances = result.utterances
                    if $0.durationSec == 0 { $0.durationSec = result.durationSec }
                }
                self.emit("session", ["id": id])

                try await self.summarize(id: id, templateId: nil)
            } catch is CancellationError {
                return
            } catch {
                self.fail(id, error)
            }
            self.pipelines[id] = nil
        }
    }

    private func startSummary(id: String, templateId: String?) {
        pipelines[id]?.cancel()
        pipelines[id] = Task { [weak self] in
            guard let self else { return }
            do { try await self.summarize(id: id, templateId: templateId) }
            catch is CancellationError { return }
            catch { self.fail(id, error) }
            self.pipelines[id] = nil
        }
    }

    private func retry(id: String) {
        guard let s = store.loadSession(id) else { return }
        if s.utterances.isEmpty && s.hasAudio { runPipeline(id: id) }
        else { startSummary(id: id, templateId: nil) }
    }

    private func summarize(id: String, templateId: String?) async throws {
        guard let key = secrets.get("deepseek") else { throw HypernoteError.missingKey("DeepSeek") }
        guard var session = store.loadSession(id) else { throw HypernoteError.message("Note not found.") }
        if let templateId { session.templateId = templateId }
        guard !session.utterances.isEmpty || !session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HypernoteError.message("Nothing to summarize yet — record the meeting or type some notes.")
        }
        let template = store.allTemplates().first { $0.id == session.templateId } ?? BuiltInTemplates.general
        let model = store.loadSettings().deepseekModel
        let client = DeepSeekClient(apiKey: key, session: urlSession)

        update(id) {
            $0.templateId = session.templateId
            $0.status = .summarizing
            $0.error = nil
            $0.summary = ""
        }
        emit("session", ["id": id])

        let messages = Prompts.summaryMessages(session: session, template: template)
        var summary = ""
        for try await delta in client.stream(model: model, system: messages.system, user: messages.user) {
            summary += delta
            emit("summary_delta", ["id": id, "text": delta])
        }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw HypernoteError.message("DeepSeek returned an empty summary.") }

        update(id) {
            $0.summary = summary
            $0.summaryTemplateId = template.id
            $0.status = .done
        }
        emit("session", ["id": id])

        if session.title.trimmingCharacters(in: .whitespaces).isEmpty {
            let t = Prompts.titleMessages(summary: summary)
            if let title = try? await client.complete(model: model, system: t.system, user: t.user) {
                let clean = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.# \n"))
                if !clean.isEmpty {
                    update(id) { if $0.title.isEmpty { $0.title = clean } }
                    emit("session", ["id": id])
                }
            }
        }
    }

    private func setStatus(_ id: String, _ status: SessionStatus) {
        update(id) { $0.status = status; $0.error = nil }
        emit("session", ["id": id])
    }

    private func fail(_ id: String, _ error: Error) {
        update(id) { $0.status = .error; $0.error = describe(error) }
        emit("session", ["id": id])
    }
}
