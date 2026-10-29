import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL
import TabulaUpdates

/// Local models served by Ollama: generation goes through its OpenAI-compatible endpoint, and the
/// native API lists, downloads and removes models so Settings can manage them.
public struct OllamaProvider: AIProvider {
    let inner: OpenAICompatibleProvider

    public init(_ endpoint: AIEndpoint) {
        var openAI = endpoint
        openAI.baseURL = OllamaLibrary.normalized(endpoint.baseURL) + "/v1"
        openAI.apiKey = ""
        inner = OpenAICompatibleProvider(openAI)
    }

    public func complete(_ request: AIRequest) async throws -> String {
        do {
            return try await inner.complete(request)
        } catch {
            throw Self.explained(error)
        }
    }

    public func stream(_ request: AIRequest) -> AIStream {
        let inner = inner
        return AIStream.run { continuation in
            do {
                for try await event in inner.stream(request) {
                    continuation.yield(event)
                }
            } catch {
                throw Self.explained(error)
            }
        }
    }

    /// Connection and missing-model errors in words that say what to do.
    private static func explained(_ error: any Error) -> any Error {
        if let error = error as? URLError, error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            return AIError.unavailable("Ollama isn't running. Open Ollama, or install it from ollama.com.")
        }
        if case AIError.server(let message) = error, message.contains("not found") {
            return AIError.notConfigured("The model isn't downloaded yet. Download it in Settings › AI.")
        }
        return error
    }
}

public struct OllamaLibrary: Sendable {
    public struct InstalledModel: Identifiable, Sendable, Equatable {
        public let name: String
        public let size: Int64
        public var id: String { name }
    }

    /// One line of `/api/pull` progress.
    public struct PullProgress: Sendable, Equatable {
        public let status: String
        public let fraction: Double?

        public init(status: String, fraction: Double?) {
            self.status = status
            self.fraction = fraction
        }
    }

    let baseURL: String

    public init(baseURL: String = AIProviderKind.ollama.defaultBaseURL) {
        self.baseURL = Self.normalized(baseURL)
    }

    /// The server address without trailing slashes, so paths can be appended.
    static func normalized(_ url: String) -> String {
        var url = url.trimmingCharacters(in: .whitespaces)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    private func url(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw AIError.notConfigured("The Ollama address isn't a valid URL.")
        }
        return url
    }

    /// The server version, or nil when Ollama isn't running.
    public func version() async -> String? {
        guard let url = try? url("/api/version"),
            let (data, _) = try? await URLSession.shared.data(
                for: URLRequest(url: url, timeoutInterval: Defaults.AI.inlineTimeout)
            ),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
    }

    public func installed() async throws -> [InstalledModel] {
        let (data, _) = try await URLSession.shared.data(from: try url("/api/tags"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["models"] as? [[String: Any]] ?? [])
            .compactMap { model in
                guard let name = model["name"] as? String else { return nil }
                return InstalledModel(name: name, size: (model["size"] as? NSNumber)?.int64Value ?? 0)
            }
    }

    /// Downloads a model, reporting progress as it goes.
    public func pull(_ name: String, progress: @Sendable (PullProgress) -> Void) async throws {
        var request = URLRequest(url: try url("/api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        request.timeoutInterval = .infinity
        let (lines, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIError.server("Ollama couldn't download \(name).")
        }
        for try await line in lines.lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if let error = json["error"] as? String { throw AIError.server(error) }
            let total = (json["total"] as? NSNumber)?.doubleValue
            let completed = (json["completed"] as? NSNumber)?.doubleValue
            progress(
                PullProgress(
                    status: json["status"] as? String ?? "",
                    fraction: total.flatMap { total in completed.map { $0 / max(total, 1) } }
                )
            )
        }
    }

    public func delete(_ name: String) async throws {
        var request = URLRequest(url: try url("/api/delete"))
        request.httpMethod = "DELETE"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIError.server("Ollama couldn't remove \(name).")
        }
    }
}
