import Foundation

/// JSON-file persistence under ~/Library/Application Support/Hypernote2.
public final class Store {
    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fm = FileManager.default

    public init(root: URL? = nil) {
        let base = root ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hypernote2", isDirectory: true)
        self.root = base
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    func dir(for id: String) -> URL { sessionsDir.appendingPathComponent(id, isDirectory: true) }
    public func audioURL(for id: String) -> URL { dir(for: id).appendingPathComponent("audio.m4a") }
    private func sessionFile(_ id: String) -> URL { dir(for: id).appendingPathComponent("session.json") }
    private var settingsFile: URL { root.appendingPathComponent("settings.json") }
    private var templatesFile: URL { root.appendingPathComponent("templates.json") }

    // MARK: Sessions

    public func listSessions() -> [Session] {
        let ids = (try? fm.contentsOfDirectory(atPath: sessionsDir.path)) ?? []
        return ids.compactMap(loadSession).sorted { $0.createdAt > $1.createdAt }
    }

    public func loadSession(_ id: String) -> Session? {
        guard let data = try? Data(contentsOf: sessionFile(id)) else { return nil }
        return try? decoder.decode(Session.self, from: data)
    }

    public func save(_ session: Session) throws {
        try fm.createDirectory(at: dir(for: session.id), withIntermediateDirectories: true)
        try encoder.encode(session).write(to: sessionFile(session.id), options: .atomic)
    }

    public func deleteSession(_ id: String) {
        try? fm.removeItem(at: dir(for: id))
    }

    // MARK: Settings

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsFile),
              let s = try? decoder.decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(_ settings: Settings) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: settingsFile, options: .atomic)
    }

    // MARK: Custom templates

    public func loadCustomTemplates() -> [MeetingTemplate] {
        guard let data = try? Data(contentsOf: templatesFile),
              let t = try? decoder.decode([MeetingTemplate].self, from: data) else { return [] }
        return t
    }

    public func saveCustomTemplates(_ templates: [MeetingTemplate]) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(templates).write(to: templatesFile, options: .atomic)
    }

    public func allTemplates() -> [MeetingTemplate] {
        BuiltInTemplates.all + loadCustomTemplates()
    }
}
