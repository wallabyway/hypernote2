import Foundation

public struct Utterance: Codable, Equatable {
    public var speaker: String   // AssemblyAI label: "A", "B", ...
    public var text: String
    public var startMs: Int
    public var endMs: Int

    public init(speaker: String, text: String, startMs: Int, endMs: Int) {
        self.speaker = speaker
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
    }
}

public enum SessionStatus: String, Codable {
    case idle, recording, uploading, transcribing, summarizing, done, error
}

public struct Session: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var notes: String
    public var templateId: String
    public var status: SessionStatus
    public var error: String?
    public var durationSec: Double
    public var hasAudio: Bool
    public var utterances: [Utterance]
    public var speakerNames: [String: String]
    public var summary: String
    public var summaryTemplateId: String?

    public init(id: String = UUID().uuidString, templateId: String, now: Date = Date()) {
        self.id = id
        self.title = ""
        self.createdAt = now
        self.updatedAt = now
        self.notes = ""
        self.templateId = templateId
        self.status = .idle
        self.error = nil
        self.durationSec = 0
        self.hasAudio = false
        self.utterances = []
        self.speakerNames = [:]
        self.summary = ""
        self.summaryTemplateId = nil
    }

    /// Display name for a diarization label, honouring user renames.
    public func speakerName(_ label: String) -> String {
        if let name = speakerNames[label], !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return "Speaker \(label)"
    }
}

/// Light-weight row for the sidebar list.
public struct SessionListItem: Codable, Equatable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var status: SessionStatus
    public var templateId: String
    public var durationSec: Double
    public var snippet: String

    init(_ s: Session) {
        id = s.id
        title = s.title
        createdAt = s.createdAt
        status = s.status
        templateId = s.templateId
        durationSec = s.durationSec
        let source = s.summary.isEmpty ? s.notes : s.summary
        snippet = String(source.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces).prefix(120))
    }
}

public struct TemplateSection: Codable, Equatable {
    public var title: String
    public var description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

public struct MeetingTemplate: Codable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var description: String
    public var icon: String
    public var sections: [TemplateSection]
    public var builtIn: Bool

    public init(id: String, title: String, description: String, icon: String,
                sections: [TemplateSection], builtIn: Bool = false) {
        self.id = id
        self.title = title
        self.description = description
        self.icon = icon
        self.sections = sections
        self.builtIn = builtIn
    }
}

public struct Settings: Codable, Equatable {
    public var captureSystemAudio: Bool = true
    public var defaultTemplateId: String = BuiltInTemplates.general.id
    public var deepseekModel: String = "deepseek-flash"
    /// Where "Save to Obsidian" writes Markdown files. nil = auto-detected Obsidian vault.
    public var exportFolder: String?

    public init() {}
}

public enum HypernoteError: LocalizedError, Equatable {
    case message(String)
    case api(provider: String, status: Int, detail: String)
    case missingKey(String)

    public var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .api(let provider, let status, let detail):
            return "\(provider) returned \(status): \(detail)"
        case .missingKey(let provider):
            return "Add your \(provider) API key in Settings first."
        }
    }
}
