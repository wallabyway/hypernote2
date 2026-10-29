import Foundation

public enum Prompts {
    public static func timestamp(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `[00:12] Alice: text` lines, one per diarized utterance.
    public static func transcriptText(for session: Session) -> String {
        session.utterances
            .map { "[\(timestamp(ms: $0.startMs))] \(session.speakerName($0.speaker)): \($0.text)" }
            .joined(separator: "\n")
    }

    public static let systemPrompt = """
    You are Hypernote2, an expert meeting note-taker. You turn a diarized transcript and the \
    user's own rough notes into a clear Markdown summary.

    Rules:
    - Use exactly the section headings you are given, in the given order, each as a level-2 \
    heading (`## Title`). No other level-2 headings, no preamble, no closing remarks.
    - Be concise. Prefer bullets. Do not invent facts that are not in the transcript or notes.
    - Attribute statements, decisions and action items to speakers by the names used in the \
    transcript. Never merge two different speakers.
    - Treat the user's notes as strong signals of what matters; include those points even if \
    they were only mentioned briefly.
    - If a section has nothing to report, write "None discussed."
    - Write in the language of the transcript.

    Diagrams (only where a section asks for one):
    - Write each diagram as a fenced code block that starts with ```mermaid and ends with ```. \
    It is rendered in the app and in Obsidian, so it must be valid Mermaid that parses on the \
    first try.
    - Base it only on the meeting. Keep it small: at most 12 nodes or items, with labels of a \
    few words.
    - Flowcharts: start with `flowchart LR` or `flowchart TD`. Use short ids like A, B, C and \
    put every label in double quotes, e.g. `A["Pricing page"] -->|"blocked by"| B["Legal review"]`. \
    Use `subgraph` to group by person or theme when it helps.
    - Mindmaps: start with `mindmap`, then one root such as `root((Topic))`, children indented \
    by two spaces, plain words only (no quotes, brackets or colons in the text).
    - Timelines: `timeline`, then `title ...`, then lines like `Thursday : API review`.
    - Icons are optional: a flowchart label may start with one of fa:fa-check, fa:fa-x, \
    fa:fa-user, fa:fa-users, fa:fa-calendar, fa:fa-clock, fa:fa-flag or fa:fa-warning, inside \
    the quotes, e.g. `B["fa:fa-check Approved"]` or `-->|"fa:fa-x"|`. Use them sparingly, only \
    where they add meaning (done/blocked, people, dates, risks).
    - Do not use styling, classDef, themes, `%%{init}%%` directives, other icons, HTML or emoji \
    in diagrams. Never put parentheses, quotes or colons in an unquoted label.
    """

    public static func summaryMessages(session: Session, template: MeetingTemplate)
        -> (system: String, user: String)
    {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var user = "# Meeting\n"
        user += "Title: \(session.title.isEmpty ? "Untitled" : session.title)\n"
        user += "Date: \(df.string(from: session.createdAt))\n"
        user += "Meeting type: \(template.title) — \(template.description)\n\n"

        user += "# Sections to write\n"
        for section in template.sections {
            user += "- \(section.title): \(section.description)\n"
        }

        let notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        user += "\n# My notes\n\(notes.isEmpty ? "(none)" : notes)\n"

        let transcript = transcriptText(for: session)
        user += "\n# Transcript\n\(transcript.isEmpty ? "(no transcript — use my notes only)" : transcript)\n"
        return (systemPrompt, user)
    }

    public static func titleMessages(summary: String) -> (system: String, user: String) {
        ("Reply with a meeting title of at most 6 words. No quotes, no punctuation at the end.",
         String(summary.prefix(3000)))
    }
}
