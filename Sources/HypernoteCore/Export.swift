import Foundation

/// Finds the user's Obsidian vaults from Obsidian's own config file.
public enum ObsidianVaults {
    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    /// The vault that is open in Obsidian, else the most recently used one.
    public static func preferredVault(configURL: URL = configURL) -> URL? {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]] else { return nil }
        let entries = vaults.values.compactMap { v -> (path: String, open: Bool, ts: Double)? in
            guard let path = v["path"] as? String,
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return (path, v["open"] as? Bool ?? false, (v["ts"] as? NSNumber)?.doubleValue ?? 0)
        }
        let best = entries.max { a, b in a.open != b.open ? !a.open : a.ts < b.ts }
        return best.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// Default export folder: `<vault>/Meetings`, or ~/Documents/Hypernote2 without Obsidian.
    public static func defaultFolder(configURL: URL = configURL) -> URL {
        if let vault = preferredVault(configURL: configURL) {
            return vault.appendingPathComponent("Meetings", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Hypernote2", isDirectory: true)
    }

    /// Name of the vault containing `folder`, if any (a parent directory holding `.obsidian`).
    public static func vaultName(containing folder: URL) -> String? {
        var dir = folder.standardizedFileURL
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".obsidian").path) {
                return dir.lastPathComponent
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }
}

/// Turns a note into an Obsidian-friendly Markdown file.
public enum MarkdownExport {
    /// `yyyy-MM-dd_HHmmss.md` from when the note was created, so it stays stable when the title changes.
    public static func filename(for session: Session) -> String {
        format(session.createdAt, "yyyy-MM-dd_HHmmss") + ".md"
    }

    public static func document(session: Session, template: MeetingTemplate?) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var speakers: [String] = []
        for u in session.utterances where !speakers.contains(session.speakerName(u.speaker)) {
            speakers.append(session.speakerName(u.speaker))
        }
        var front = ["---",
                     "title: \(yaml(title.isEmpty ? "Untitled meeting" : title))",
                     "date: \(dateString(session.createdAt))",
                     "time: \(yaml(timeString(session.createdAt)))"]
        if session.durationSec > 0 { front.append("duration_min: \(Int((session.durationSec / 60).rounded()))") }
        if let template { front.append("template: \(yaml(template.title))") }
        if !speakers.isEmpty { front.append("speakers: [\(speakers.map(yaml).joined(separator: ", "))]") }
        front += ["tags: [meeting, hypernote]", "---", ""]

        var body = front.joined(separator: "\n")
        body += "# \(title.isEmpty ? "Untitled meeting" : title)\n\n"
        body += session.summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { body += "\n## My Notes\n\n\(notes)\n" }
        return body
    }

    /// Writes the note into `folder` (created if needed), replacing an earlier export of the same note.
    @discardableResult
    public static func write(session: Session, template: MeetingTemplate?, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename(for: session))
        try document(session: session, template: template).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func dateString(_ d: Date) -> String { format(d, "yyyy-MM-dd") }
    private static func timeString(_ d: Date) -> String { format(d, "HH:mm") }
    private static func format(_ d: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: d)
    }
}
