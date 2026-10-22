import Foundation

extension Session {
    /// A single text answer without tools, scene context or conversation
    /// history: for rewriting prose, drafting commit messages and similar
    /// self-contained requests. Nothing is recorded in the session.
    public func complete(instructions: String, prompt: String, maxTokens: Int? = nil) async throws -> String {
        let limit = maxTokens ?? config.maxTokens
        let body: [String: Any]
        switch config.apiFormat {
        case .anthropic:
            body = ["model": config.model, "max_tokens": limit, "system": instructions,
                    "messages": [["role": "user", "content": prompt]]]
        case .openAICompatible:
            body = ["model": config.model, "max_tokens": limit,
                    "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]]]
        case .openAIResponses:
            body = ["model": config.model, "max_output_tokens": limit, "instructions": instructions, "input": prompt]
        }
        let text = try Self.completionText(from: await post(body), format: config.apiFormat)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionError.malformedResponse(detail: "the model returned no text")
        }
        return text
    }

    static func completionText(from data: Data, format: SessionAPIFormat) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionError.malformedResponse(detail: "top-level JSON is not an object")
        }
        switch format {
        case .anthropic:
            let content = json["content"] as? [[String: Any]] ?? []
            return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .openAICompatible:
            let choices = json["choices"] as? [[String: Any]]
            return (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        case .openAIResponses:
            let output = json["output"] as? [[String: Any]] ?? []
            return output.filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined()
        }
    }
}
