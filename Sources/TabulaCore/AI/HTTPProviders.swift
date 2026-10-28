import Foundation

/// Claude through the Messages API (`POST /v1/messages`).
public struct AnthropicProvider: AIProvider {
    let endpoint: AIEndpoint

    public init(_ endpoint: AIEndpoint) {
        self.endpoint = endpoint
    }

    private func httpRequest(_ request: AIRequest, stream: Bool) throws -> URLRequest {
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
        if stream { body["stream"] = true }
        // Inline suggestions must come back while the user is still looking at the caret.
        if request.purpose == .inline {
            body["output_config"] = ["effort": "low"]
        } else {
            if let effort = endpoint.effort { body["output_config"] = ["effort": effort] }
            // Current models think by default but return the reasoning empty unless asked for a summary.
            // Older ones (before 4.6) only take a token budget and would reject this.
            if Self.takesAdaptiveThinking(endpoint.model) { body["thinking"] = ["type": "adaptive", "display": "summarized"] }
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        return http
    }

    /// Claude models from 4.6 on (Opus, Sonnet, Haiku, Fable, Mythos) take adaptive thinking; ids look like
    /// `claude-opus-5-5`, `claude-sonnet-4-6-20260101` or `anthropic/claude-haiku-5-5` behind a gateway.
    static func takesAdaptiveThinking(_ model: String) -> Bool {
        let pattern = #"claude-(?:opus|sonnet|haiku|fable|mythos)-(\d+)(?:-(\d{1,2})(?!\d))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: model, range: NSRange(location: 0, length: (model as NSString).length)) else { return false }
        let major = Int((model as NSString).substring(with: match.range(at: 1))) ?? 0
        let minor = match.range(at: 2).location == NSNotFound ? 0 : Int((model as NSString).substring(with: match.range(at: 2))) ?? 0
        return major > 4 || (major == 4 && minor >= 6)
    }

    private static func errorMessage(_ data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
        return "Claude API: \(message)"
    }

    public func complete(_ request: AIRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: try httpRequest(request, stream: false))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError.server(Self.errorMessage(data))
        }
        if json["stop_reason"] as? String == "refusal" { throw AIError.refused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    public func stream(_ request: AIRequest) -> AIStream {
        AIStream.run { continuation in
            try await ServerSentEvents.stream(try httpRequest(request, stream: true), describeError: Self.errorMessage) { payload in
                guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
                switch event["type"] as? String {
                case "content_block_delta":
                    let delta = event["delta"] as? [String: Any] ?? [:]
                    switch delta["type"] as? String {
                    case "thinking_delta": if let text = delta["thinking"] as? String { continuation.yield(.thinking(text)) }
                    case "text_delta": if let text = delta["text"] as? String { continuation.yield(.text(text)) }
                    default: break
                    }
                case "message_delta":
                    if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { throw AIError.refused }
                case "error":
                    let message = (event["error"] as? [String: Any])?["message"] as? String ?? payload
                    throw AIError.server("Claude API: \(message)")
                default:
                    break
                }
            }
        }
    }
}

/// Any server speaking the OpenAI chat-completions format: LiteLLM, LM Studio, llama.cpp, vLLM, OpenAI, Ollama.
public struct OpenAICompatibleProvider: AIProvider {
    let endpoint: AIEndpoint

    public init(_ endpoint: AIEndpoint) {
        self.endpoint = endpoint
    }

    private func httpRequest(_ request: AIRequest, stream: Bool) throws -> URLRequest {
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
        if stream { body["stream"] = true }
        // OpenAI reasoning models (and LiteLLM, which maps it for others) take this.
        if let effort = endpoint.effort { body["reasoning_effort"] = effort }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)
        return http
    }

    private func errorMessage(_ data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data, as: UTF8.self)
        return message.isEmpty ? "The server at \(endpoint.baseURL) didn't answer." : message
    }

    public func complete(_ request: AIRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: try httpRequest(request, stream: false))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIError.server(errorMessage(data))
        }
        let choices = json["choices"] as? [[String: Any]] ?? []
        let content = (choices.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        // Reasoning that some servers leave in the text as <think>…</think> isn't part of the answer.
        var splitter = ThinkTagSplitter()
        let events = splitter.feed(content) + splitter.finish()
        return events.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    public func stream(_ request: AIRequest) -> AIStream {
        AIStream.run { continuation in
            var splitter = ThinkTagSplitter()
            try await ServerSentEvents.stream(try httpRequest(request, stream: true), describeError: errorMessage) { payload in
                guard payload != "[DONE]", let chunk = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
                if let error = chunk["error"] as? [String: Any] { throw AIError.server(error["message"] as? String ?? payload) }
                let delta = ((chunk["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]) ?? [:]
                // DeepSeek, vLLM and LiteLLM send reasoning as reasoning_content; OpenRouter and Ollama as reasoning.
                if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
                    continuation.yield(.thinking(reasoning))
                }
                if let content = delta["content"] as? String, !content.isEmpty {
                    for event in splitter.feed(content) { continuation.yield(event) }
                }
            }
            for event in splitter.finish() { continuation.yield(event) }
        }
    }
}
