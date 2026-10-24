import Foundation

/// A coding agent already installed on the Mac (Claude Code or Codex), run non-interactively.
/// Apps opened from the Finder don't get the user's shell PATH (nvm, Homebrew, ~/.local/bin), so
/// commands run through the user's login shell to find the tool the same way Terminal would.
public struct CLIProvider: AIProvider {
    public enum Tool: String, Sendable {
        case claude, codex
    }

    let tool: Tool
    let model: String

    public init(tool: Tool, settings: AISettings) {
        self.tool = tool
        self.model = settings.model
    }

    /// The tool's path as the login shell resolves it, or nil when it isn't installed.
    public static func locate(_ tool: Tool) async -> String? {
        guard let output = try? await ShellCommand.run(script: #"command -v "$0""#, arguments: [tool.rawValue],
                                                       timeout: Defaults.AI.inlineTimeout) else { return nil }
        let path = output.stdout.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    public func complete(_ request: AIRequest) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabulaAI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        switch tool {
        case .claude:
            // No tools: the agent only answers. JSON output separates the answer from anything the shell prints.
            var arguments = ["-p", request.prompt, "--system-prompt", request.instructions, "--tools", "", "--output-format", "json"]
            if !model.isEmpty { arguments += ["--model", model] }
            let output = try await ShellCommand.run(script: #""$0" "$@""#, arguments: ["claude"] + arguments,
                                                    directory: directory, timeout: Defaults.AI.generateTimeout)
            for line in output.stdout.split(whereSeparator: \.isNewline).reversed() {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if json["is_error"] as? Bool == true { throw AIError.server(json["result"] as? String ?? "Claude Code failed.") }
                if let result = json["result"] as? String { return result }
            }
            throw AIError.server(Self.failure("Claude Code", output))
        case .codex:
            // Read-only sandbox; the final answer is written to a file, apart from the progress log.
            let answer = directory.appendingPathComponent("answer.txt")
            var arguments = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--output-last-message", answer.path]
            if !model.isEmpty { arguments += ["--model", model] }
            arguments.append(request.instructions + "\n\n" + request.prompt)
            let output = try await ShellCommand.run(script: #""$0" "$@""#, arguments: ["codex"] + arguments,
                                                    directory: directory, timeout: Defaults.AI.generateTimeout)
            if let text = try? String(contentsOf: answer, encoding: .utf8), !text.isEmpty { return text }
            throw AIError.server(Self.failure("Codex", output))
        }
    }

    private static func failure(_ name: String, _ output: ShellCommand.Output) -> String {
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.status == ShellCommand.notFoundStatus { return "\(name) isn't installed, or isn't on your shell's PATH." }
        return detail.isEmpty ? "\(name) exited with status \(output.status)." : "\(name): \(detail.suffix(Defaults.AI.errorLength))"
    }
}

/// Runs a script in the user's login shell, with arguments passed separately (never interpolated).
enum ShellCommand {
    struct Output: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    /// What shells return when the command isn't found.
    static let notFoundStatus: Int32 = 127

    static func run(script: String, arguments: [String], directory: URL? = nil, timeout: Double) async throws -> Output {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l and -i load the same profile files as a Terminal window, where PATH is set up.
        process.arguments = ["-l", "-i", "-c", script] + arguments
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTimeout(seconds: timeout, "The command", discard: { _ in }) {
            try await withCheckedThrowingContinuation { continuation in
                // Both pipes are drained while the process runs, so a chatty tool can't fill one and block.
                let collected = Collected()
                stdout.fileHandleForReading.readabilityHandler = { collected.append(out: $0.availableData) }
                stderr.fileHandleForReading.readabilityHandler = { collected.append(err: $0.availableData) }
                process.terminationHandler = { finished in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    collected.append(out: stdout.fileHandleForReading.readDataToEndOfFile())
                    collected.append(err: stderr.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: collected.output(status: finished.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()

        func append(out data: Data) { lock.withLock { out.append(data) } }
        func append(err data: Data) { lock.withLock { err.append(data) } }
        func output(status: Int32) -> Output {
            lock.withLock { Output(stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), status: status) }
        }
    }
}
