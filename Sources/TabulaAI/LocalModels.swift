import CryptoKit
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// A model file Tabula can run itself (GGUF, the format llama.cpp reads).
public struct LocalModel: Identifiable, Hashable, Sendable {
    /// The file name in the models folder; also what the settings store.
    public var id: String
    public var name: String
    public var summary: String
    /// Where it downloads from; nil for a file the user added.
    public var url: URL?
    public var size: Int64
    /// Published SHA-256, checked after downloading.
    public var sha256: String?
    /// Small enough to answer while the user types.
    public var forTyping: Bool

    public init(id: String, name: String, summary: String, url: URL?, size: Int64, sha256: String?, forTyping: Bool) {
        self.id = id
        self.name = name
        self.summary = summary
        self.url = url
        self.size = size
        self.sha256 = sha256
        self.forTyping = forTyping
    }

    /// Light models offered for download, smallest first. Sizes and hashes are those Hugging Face publishes.
    public static let catalog: [LocalModel] = [
        hf(
            "Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF",
            "qwen2.5-coder-0.5b-instruct-q4_k_m.gguf",
            "Qwen2.5 Coder 0.5B",
            "Fastest. Good for suggestions while typing.",
            491_400_064,
            "1d9614638d18024d0fbb36575a15f1302a3adf044df10345688ec4f6e1c4ff32",
            typing: true
        ),
        hf(
            "bartowski/Llama-3.2-1B-Instruct-GGUF",
            "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
            "Llama 3.2 1B",
            "Fast general model (Llama 3.2 Community License).",
            807_694_464,
            "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
            typing: true
        ),
        hf(
            "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF",
            "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
            "Qwen2.5 Coder 1.5B",
            "Fast suggestions that know SQL better.",
            1_117_320_768,
            "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046",
            typing: true
        ),
        hf(
            "bartowski/Llama-3.2-3B-Instruct-GGUF",
            "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            "Llama 3.2 3B",
            "Writes whole queries; general knowledge (Llama 3.2 Community License).",
            2_019_377_696,
            "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            typing: false
        ),
        hf(
            "Qwen/Qwen2.5-Coder-3B-Instruct-GGUF",
            "qwen2.5-coder-3b-instruct-q4_k_m.gguf",
            "Qwen2.5 Coder 3B",
            "Writes whole queries well on most Macs.",
            2_104_932_800,
            "724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7",
            typing: false
        ),
        hf(
            "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF",
            "qwen2.5-coder-7b-instruct-q4_k_m.gguf",
            "Qwen2.5 Coder 7B",
            "Best local queries; 16 GB of memory recommended.",
            4_683_073_536,
            "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c",
            typing: false
        ),
    ]

    private static func hf(
        _ repo: String,
        _ file: String,
        _ name: String,
        _ summary: String,
        _ size: Int64,
        _ sha256: String,
        typing: Bool
    ) -> LocalModel {
        LocalModel(
            id: file,
            name: name,
            summary: summary,
            url: URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)"),
            size: size,
            sha256: sha256,
            forTyping: typing
        )
    }
}

/// The folder of model files Tabula runs: download, add, list and delete.
public struct LocalModelStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula/Models", isDirectory: true)
    }

    public func path(for id: String) -> URL { directory.appendingPathComponent(id) }

    /// Model files present, with their sizes.
    public func installed() -> [(id: String, size: Int64)] {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))
            ?? []
        return files.filter { $0.pathExtension.lowercased() == "gguf" }
            .map { ($0.lastPathComponent, Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    public func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: path(for: id).path)
    }

    /// Downloads a model, checking its size and SHA-256 when known. Progress is reported as a fraction.
    public func download(_ model: LocalModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = model.url else {
            throw AIError.notConfigured("This model has no download address.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let delegate = DownloadProgress(expected: model.size, report: progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AIError.server("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try Self.checkGGUF(temporary)
        if let expected = model.sha256 {
            guard try Self.sha256(of: temporary) == expected else {
                throw AIError.server("The download is damaged (checksum mismatch). Try again.")
            }
        }
        let target = path(for: model.id)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    /// A model from any link (e.g. a Hugging Face "resolve" URL to a .gguf file).
    public func model(from link: URL) throws -> LocalModel {
        let name = link.lastPathComponent
        guard name.lowercased().hasSuffix(".gguf") else {
            throw AIError.notConfigured("The link must point to a .gguf file.")
        }
        return LocalModel(
            id: name,
            name: name,
            summary: link.host ?? "",
            url: link,
            size: 0,
            sha256: nil,
            forTyping: false
        )
    }

    /// Adds a model file from disk. On APFS the copy is a clone, so it takes no extra space.
    @discardableResult
    public func add(_ file: URL) throws -> String {
        try Self.checkGGUF(file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = path(for: file.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            return target.lastPathComponent
        }
        try FileManager.default.copyItem(at: file, to: target)
        return target.lastPathComponent
    }

    public func delete(_ id: String) throws {
        try FileManager.default.removeItem(at: path(for: id))
    }

    /// GGUF files start with "GGUF"; anything else (an HTML error page, another format) is refused.
    static func checkGGUF(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("GGUF".utf8) else {
            throw AIError.notConfigured("\(file.lastPathComponent) isn't a GGUF model file.")
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Reports a download's progress, in whole percent steps.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expected: Int64
    let report: @Sendable (Double) -> Void
    private var reported = 0.0

    init(expected: Int64, report: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard total > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(total))
        if fraction - reported >= Defaults.AI.downloadProgressStep {
            reported = fraction
            report(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    }
}

/// Runs a model file from the store with llama.cpp, inside the app.
public struct BuiltInProvider: AIProvider {
    let endpoint: AIEndpoint
    let store: LocalModelStore

    public init(_ endpoint: AIEndpoint, store: LocalModelStore = LocalModelStore()) {
        self.endpoint = endpoint
        self.store = store
    }

    public func complete(_ request: AIRequest) async throws -> String {
        guard !endpoint.model.isEmpty else {
            throw AIError.notConfigured("Download or add a model in Settings › AI.")
        }
        guard store.isInstalled(endpoint.model) else {
            throw AIError.notConfigured("\(endpoint.model) isn't downloaded yet. Download it in Settings › AI.")
        }
        let path = store.path(for: endpoint.model).path
        if request.purpose == .inline, let fill = request.fill,
            let completion = try await LocalModelRunner.shared.fill(
                path: path,
                prefix: fill.prefix,
                suffix: fill.suffix,
                maxTokens: Defaults.AI.localInlineTokens
            )
        {
            return completion
        }
        return try await LocalModelRunner.shared.generate(
            path: path,
            instructions: request.instructions,
            prompt: request.prompt,
            maxTokens: request.purpose == .inline ? Defaults.AI.localInlineTokens : Defaults.AI.localGenerateTokens,
            stopAtNewline: request.purpose == .inline
        )
    }

    /// Tokens as the model writes them; models that reason in <think> tags (Qwen3, DeepSeek-R1) show it as thinking.
    public func stream(_ request: AIRequest) -> AIStream {
        guard request.purpose != .inline else {
            return AIStream.run { continuation in continuation.yield(.text(try await complete(request))) }
        }
        return AIStream.run { continuation in
            guard !endpoint.model.isEmpty else {
                throw AIError.notConfigured("Download or add a model in Settings › AI.")
            }
            guard store.isInstalled(endpoint.model) else {
                throw AIError.notConfigured("\(endpoint.model) isn't downloaded yet. Download it in Settings › AI.")
            }
            let splitter = ThinkTagStream(continuation)
            _ = try await LocalModelRunner.shared.generate(
                path: store.path(for: endpoint.model).path,
                instructions: request.instructions,
                prompt: request.prompt,
                maxTokens: Defaults.AI.localGenerateTokens,
                onText: { splitter.feed($0) }
            )
            splitter.finish()
        }
    }
}
