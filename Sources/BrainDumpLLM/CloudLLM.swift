import BrainDumpCore
import Foundation

public enum CloudLLMError: LocalizedError {
    case badKey
    case rateLimited
    case server(Int, String)
    case http(Int, String)
    case refused
    case truncated
    case noText
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .badKey: return "The Anthropic API key was rejected (401)."
        case .rateLimited: return "Rate limited by the Anthropic API (429). Try again shortly."
        case .server(let code, let message): return "Anthropic API server error (\(code)): \(message)"
        case .http(let code, let message): return "Anthropic API error (\(code)): \(message)"
        case .refused: return "The model declined to answer."
        case .truncated: return "The model ran out of output tokens."
        case .noText: return "The response contained no text."
        case .badResponse: return "The response could not be read."
        }
    }
}

/// Anthropic Messages API over HTTPS. Ignores GBNF grammars; the line format is followed from the few-shot turns
/// and checked by the validator.
public struct CloudLLM: LLMProvider {
    public static let defaultModel = "claude-opus-5-5"

    public let apiKey: String
    public let model: String
    /// JSON schema string sent as the structured output format; nil sends none.
    public var outputSchema: String?
    public var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, model: String = CloudLLM.defaultModel) {
        self.apiKey = apiKey
        self.model = model
    }

    public func complete(turns: [ChatTurn], grammar: String?, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(turns: turns, maxTokens: maxTokens))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = Self.errorMessage(data)
            switch status {
            case 401: throw CloudLLMError.badKey
            case 429: throw CloudLLMError.rateLimited
            case 500...599: throw CloudLLMError.server(status, message)
            default: throw CloudLLMError.http(status, message)
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudLLMError.badResponse }
        switch json["stop_reason"] as? String {
        case "refusal": throw CloudLLMError.refused
        case "max_tokens": throw CloudLLMError.truncated
        default: break
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            throw CloudLLMError.noText
        }
        return text
    }

    func body(turns: [ChatTurn], maxTokens: Int) throws -> [String: Any] {
        let system = turns.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let messages = turns.filter { $0.role != .system }.map { ["role": $0.role.rawValue, "content": $0.content] }
        var outputConfig: [String: Any] = ["effort": "low"]
        if let outputSchema, let schema = try JSONSerialization.jsonObject(with: Data(outputSchema.utf8)) as? [String: Any] {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        var body: [String: Any] = [
            "model": model,
            // The model always thinks and thinking tokens count against max_tokens.
            "max_tokens": max(8000, maxTokens),
            "messages": messages,
            "output_config": outputConfig,
            "fallbacks": "default",
        ]
        if !system.isEmpty { body["system"] = system }
        return body
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String
        {
            return message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}
