import Foundation

/// DeepSeek chat completions (OpenAI-compatible), Flash model, non-thinking mode.
public struct DeepSeekClient {
    public static let base = URL(string: "https://api.deepseek.com")!
    public static let fallbackModel = "deepseek-flash"
    let apiKey: String
    let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (obj?["error"] as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw HypernoteError.api(provider: "DeepSeek", status: http.statusCode, detail: detail)
        }
    }

    /// Prefer the documented Flash id, then any other "flash" model the account exposes.
    public static func pickFlashModel(from ids: [String]) -> String {
        for preferred in ["deepseek-flash", "deepseek-v4-flash"] where ids.contains(preferred) {
            return preferred
        }
        return ids.first { $0.lowercased().contains("flash") } ?? fallbackModel
    }

    /// Validates the key and returns the Flash model id to use.
    public func verifyAndPickModel() async throws -> String {
        let (data, response) = try await session.data(for: request("models"))
        try Self.check(response, data: data)
        let ids = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String } ?? []
        return Self.pickFlashModel(from: ids)
    }

    func chatBody(model: String, system: String, user: String, stream: Bool, maxTokens: Int?) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "stream": stream,
            "thinking": ["type": "disabled"],   // summaries do not need chain-of-thought; keeps it fast
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Streams the completion as text fragments.
    public func stream(model: String, system: String, user: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request("chat/completions", method: "POST")
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.timeoutInterval = 300
                    req.httpBody = try chatBody(model: model, system: system, user: user,
                                                stream: true, maxTokens: nil)

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        try Self.check(response, data: body)
                    }
                    for try await line in bytes.lines {
                        if line == "data: [DONE]" { break }
                        if let delta = Self.parseSSELine(line) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func complete(model: String, system: String, user: String, maxTokens: Int = 40) async throws -> String {
        var req = request("chat/completions", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try chatBody(model: model, system: system, user: user, stream: false, maxTokens: maxTokens)
        let (data, response) = try await session.data(for: req)
        try Self.check(response, data: data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((obj?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
        return (message?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts `choices[0].delta.content` from one SSE `data:` line.
    public static func parseSSELine(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return nil }
        return content
    }
}
