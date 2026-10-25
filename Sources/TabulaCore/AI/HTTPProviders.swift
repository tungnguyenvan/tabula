import Foundation

/// Claude through the Messages API (`POST /v1/messages`).
public struct AnthropicProvider: AIProvider {
    let endpoint: AIEndpoint

    public init(_ endpoint: AIEndpoint) {
        self.endpoint = endpoint
    }

    public func complete(_ request: AIRequest) async throws -> String {
        guard !endpoint.apiKey.isEmpty else { throw AIError.notConfigured("Add a Claude API key in Settings → AI.") }
        guard let url = URL(string: endpoint.baseURL)?.appendingPathComponent("v1/messages") else { throw AIError.notConfigured("The API address isn't a valid URL.") }
        var http = URLRequest(url: url, timeoutInterval: request.purpose == .inline ? Defaults.AI.inlineTimeout : Defaults.AI.generateTimeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "content-type")
        http.setValue(endpoint.apiKey, forHTTPHeaderField: "x-api-key")
        http.setValue(Defaults.AI.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        // If a safety classifier declines, the server retries on a suitable model instead of failing.
        http.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        var body: [String: Any] = [
            "model": endpoint.model,
            "max_tokens": request.maxTokens,
            "system": request.instructions,
            "messages": [["role": "user", "content": request.prompt]],
            "fallbacks": "default",
        ]
        // Inline suggestions must come back while the user is still looking at the caret.
        if request.purpose == .inline {
            body["output_config"] = ["effort": "low"]
        } else if let effort = endpoint.effort {
            body["output_config"] = ["effort": effort]
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: http)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
            throw AIError.server("Claude API: \(message)")
        }
        if json["stop_reason"] as? String == "refusal" { throw AIError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }
}

/// Any server speaking the OpenAI chat-completions format: LiteLLM, LM Studio, llama.cpp, vLLM, OpenAI, Ollama.
public struct OpenAICompatibleProvider: AIProvider {
    let endpoint: AIEndpoint

    public init(_ endpoint: AIEndpoint) {
        self.endpoint = endpoint
    }

    public func complete(_ request: AIRequest) async throws -> String {
        let model = endpoint.model
        guard !model.isEmpty else { throw AIError.notConfigured("Choose a model in Settings → AI.") }
        guard let url = URL(string: endpoint.baseURL)?.appendingPathComponent("chat/completions") else { throw AIError.notConfigured("The API address isn't a valid URL.") }
        var http = URLRequest(url: url, timeoutInterval: request.purpose == .inline ? Defaults.AI.inlineTimeout : Defaults.AI.generateTimeout)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty { http.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "messages": [["role": "system", "content": request.instructions], ["role": "user", "content": request.prompt]],
        ]
        // OpenAI reasoning models (and LiteLLM, which maps it for others) take this.
        if let effort = endpoint.effort { body["reasoning_effort"] = effort }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: http)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let json else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
            throw AIError.server(message.isEmpty ? "The server at \(endpoint.baseURL) didn't answer." : message)
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        return (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
    }
}
