import Foundation

public struct TranscriptResult: Equatable {
    public var utterances: [Utterance]
    public var durationSec: Double
}

/// Pre-recorded transcription with speaker diarization (`speaker_labels`).
public struct AssemblyAIClient {
    public static let base = URL(string: "https://api.assemblyai.com")!
    let apiKey: String
    let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "authorization")
        return req
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw HypernoteError.api(provider: "AssemblyAI", status: http.statusCode, detail: detail)
        }
    }

    /// Cheap authenticated call; throws on a bad key.
    public func verify() async throws {
        let (data, response) = try await session.data(
            for: request("v2/transcript", query: [URLQueryItem(name: "limit", value: "1")]))
        try Self.check(response, data: data)
    }

    /// Streams the file from disk; returns the temporary `upload_url`.
    public func upload(fileURL: URL) async throws -> String {
        var req = request("v2/upload", method: "POST")
        req.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 600
        let (data, response) = try await session.upload(for: req, fromFile: fileURL)
        try Self.check(response, data: data)
        guard let url = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["upload_url"] as? String
        else { throw HypernoteError.message("AssemblyAI upload returned no URL.") }
        return url
    }

    public func createTranscript(audioURL: String) async throws -> String {
        var req = request("v2/transcript", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio_url": audioURL,
            "speaker_labels": true,
        ])
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data: data)
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
        else { throw HypernoteError.message("AssemblyAI returned no transcript id.") }
        return id
    }

    /// Polls until the job completes or fails.
    public func waitForTranscript(id: String, pollEvery: Duration = .seconds(3),
                                  timeout: Duration = .seconds(3 * 3600)) async throws -> TranscriptResult {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let (data, response) = try await session.data(for: request("v2/transcript/\(id)"))
            try Self.check(response, data: data)
            let status = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
            switch status {
            case "completed": return try Self.parseTranscript(data)
            case "error":
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                throw HypernoteError.message("AssemblyAI failed: \(message ?? "unknown error")")
            default: try await Task.sleep(for: pollEvery)
            }
        }
        throw HypernoteError.message("Timed out waiting for AssemblyAI.")
    }

    /// Turns a completed transcript payload into speaker-labelled utterances.
    public static func parseTranscript(_ data: Data) throws -> TranscriptResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HypernoteError.message("Unexpected AssemblyAI response.")
        }
        let duration = (json["audio_duration"] as? NSNumber)?.doubleValue ?? 0

        if let raw = json["utterances"] as? [[String: Any]], !raw.isEmpty {
            let utterances = raw.compactMap { u -> Utterance? in
                guard let text = u["text"] as? String, !text.isEmpty else { return nil }
                return Utterance(
                    speaker: (u["speaker"] as? String) ?? "A",
                    text: text,
                    startMs: (u["start"] as? NSNumber)?.intValue ?? 0,
                    endMs: (u["end"] as? NSNumber)?.intValue ?? 0)
            }
            return TranscriptResult(utterances: utterances, durationSec: duration)
        }

        // No diarization output (e.g. a single speaker, very short audio): keep the plain text.
        if let text = json["text"] as? String, !text.isEmpty {
            return TranscriptResult(
                utterances: [Utterance(speaker: "A", text: text, startMs: 0, endMs: Int(duration * 1000))],
                durationSec: duration)
        }
        return TranscriptResult(utterances: [], durationSec: duration)
    }
}
