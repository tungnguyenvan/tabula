import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL
import TabulaUpdates

/// A piece of a model's answer as it is generated: its reasoning ("thinking") or the answer itself.
public enum AIStreamEvent: Sendable, Equatable {
    case thinking(String)
    case text(String)
}

public typealias AIStream = AsyncThrowingStream<AIStreamEvent, any Error>

extension AIProvider {
    /// Backends that can't stream send the whole answer at the end.
    public func stream(_ request: AIRequest) -> AIStream {
        AIStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.text(try await complete(request)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AIStream {
    /// Runs `body`, which yields events, as a cancellable stream.
    public static func run(_ body: @escaping @Sendable (Continuation) async throws -> Void) -> AIStream {
        AIStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects a stream into the whole answer (the reasoning is dropped).
    public func text() async throws -> String {
        var text = ""
        for try await event in self {
            if case .text(let piece) = event { text += piece }
        }
        return text
    }
}

/// Splits `<think>…</think>`, where DeepSeek-R1, Qwen3 and other open models put their reasoning, out of
/// streamed text. Tags can arrive split across chunks, so a possible tag is held back until it is known.
/// Only a block at the very start of the answer counts as reasoning.
struct ThinkTagSplitter {
    private static let open = "<think>", close = "</think>"
    private enum State { case start, thinking, text }
    private var state = State.start
    private var buffer = ""
    /// After `</think>`, the blank lines before the answer are dropped.
    private var trimLeading = false

    mutating func feed(_ chunk: String) -> [AIStreamEvent] {
        buffer += chunk
        var events: [AIStreamEvent] = []
        while true {
            switch state {
            case .start:
                let trimmed = buffer.drop(while: \.isWhitespace)
                if trimmed.hasPrefix(Self.open) {
                    buffer = String(trimmed.dropFirst(Self.open.count))
                    state = .thinking
                } else if trimmed.isEmpty || Self.open.hasPrefix(trimmed) {
                    return events
                } else {
                    state = .text
                }
            case .thinking:
                if let range = buffer.range(of: Self.close) {
                    let reasoning = String(buffer[..<range.lowerBound])
                    if !reasoning.isEmpty { events.append(.thinking(reasoning)) }
                    buffer = String(buffer[range.upperBound...])
                    state = .text
                    trimLeading = true
                } else {
                    let keep =
                        (1..<Self.close.count).reversed().first { buffer.hasSuffix(String(Self.close.prefix($0))) } ?? 0
                    let reasoning = String(buffer.dropLast(keep))
                    if !reasoning.isEmpty { events.append(.thinking(reasoning)) }
                    buffer = String(buffer.suffix(keep))
                    return events
                }
            case .text:
                if trimLeading {
                    buffer = String(buffer.drop(while: \.isWhitespace))
                    if buffer.isEmpty { return events }
                    trimLeading = false
                }
                if !buffer.isEmpty { events.append(.text(buffer)) }
                buffer = ""
                return events
            }
        }
    }

    mutating func finish() -> [AIStreamEvent] {
        defer { buffer = "" }
        switch state {
        case .thinking: return buffer.isEmpty ? [] : [.thinking(buffer)]
        case .start, .text: return buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.text(buffer)]
        }
    }
}

/// A splitter that callbacks on another thread can feed (they arrive one at a time, in order).
final class ThinkTagStream: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = ThinkTagSplitter()
    private let continuation: AIStream.Continuation

    init(_ continuation: AIStream.Continuation) { self.continuation = continuation }

    func feed(_ text: String) {
        lock.withLock { splitter.feed(text) }.forEach { continuation.yield($0) }
    }

    func finish() {
        lock.withLock { splitter.finish() }.forEach { continuation.yield($0) }
    }
}

/// Server-sent events: the `data:` payload of each event, as lines arrive.
enum ServerSentEvents {
    /// Sends `request` and calls `handle` with each `data:` payload. A non-200 answer is thrown with its body.
    static func stream(
        _ request: URLRequest,
        describeError: (Data) -> String,
        handle: (String) throws -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            throw AIError.server(describeError(body))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            try handle(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces))
        }
    }
}
