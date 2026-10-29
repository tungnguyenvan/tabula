import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// A coding agent already installed on the Mac (Claude Code or Codex), run non-interactively.
/// Apps opened from the Finder don't get the user's shell PATH (nvm, Homebrew, ~/.local/bin), so
/// commands run through the user's login shell to find the tool the same way Terminal would.
public struct CLIProvider: AIProvider {
    public enum Tool: String, Sendable {
        case claude, codex
    }

    let tool: Tool
    let model: String
    let effort: String?
    /// The tool's path when it is known in advance (tests); otherwise it is located (`locate`).
    let executable: String?

    public init(tool: Tool, model: String = "", effort: String? = nil) {
        self.init(tool: tool, model: model, effort: effort, executable: nil)
    }

    init(tool: Tool, model: String, effort: String?, executable: String?) {
        self.tool = tool
        self.model = model
        self.effort = effort
        self.executable = executable
    }

    /// Paths already found, so each request doesn't start a login shell to look again (about half a second).
    private static let located = LocatedTools()

    /// The tool's path: as the login shell resolves it, else from the usual install locations (an npm
    /// install under another nvm Node version isn't on the PATH). Nil when it isn't installed. A path found
    /// before is used again while the file is still there.
    public static func locate(_ tool: Tool) async -> String? {
        if let known = located.path(for: tool), FileManager.default.isExecutableFile(atPath: known) {
            return known
        }
        let found = await search(tool)
        located.set(found, for: tool)
        return found
    }

    private static func search(_ tool: Tool) async -> String? {
        // A shell that can't run falls back to the usual install locations below.
        if let output = try? await ShellCommand.run(
            script: #"command -v "$0""#,
            arguments: [tool.rawValue],
            timeout: Defaults.AI.inlineTimeout
        ),
            let path = output.stdout.split(whereSeparator: \.isNewline).last.map(String.init), path.hasPrefix("/")
        {
            return path
        }
        return installLocations(for: tool).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func installLocations(for tool: Tool) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvm = home + "/.nvm/versions/node"
        // Newest Node version first.
        let nodeVersions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvm)/\($0)/bin" }
        let directories =
            [home + "/.local/bin", home + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", home + "/.bun/bin"]
            + nodeVersions
        return directories.map { "\($0)/\(tool.rawValue)" }
    }

    public func complete(_ request: AIRequest) async throws -> String {
        try await stream(request).text()
    }

    /// The agent's output as it works: Claude Code's partial messages (thinking and text), Codex's reasoning and
    /// answer events. A tool that prints no events (an old version) still gives its final answer at the end.
    public func stream(_ request: AIRequest) -> AIStream {
        let tool = tool
        let model = model
        let effort = effort
        let known = executable
        return AIStream.run { continuation in
            let located: String?
            if let known {
                located = known
            } else {
                located = await Self.locate(tool)
            }
            guard let executable = located else {
                throw AIError.unavailable(
                    "\(tool == .claude ? "Claude Code" : "Codex") isn't installed, or isn't on your shell's PATH."
                )
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TabulaAI-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let events = CLIEvents(continuation)
            // The prompt goes to the tool from a file: on the shell's own standard input, a profile script that
            // reads input (an update prompt, for one) would take it before the tool starts.
            let prompt = directory.appendingPathComponent("prompt.txt")

            switch tool {
            case .claude:
                try request.prompt.write(to: prompt, atomically: true, encoding: .utf8)
                let output = try await ShellCommand.run(
                    script: Self.fromPromptFile,
                    arguments: [executable, prompt.path] + Self.claudeArguments(request, model: model, effort: effort),
                    directory: directory,
                    timeout: Defaults.AI.generateTimeout,
                    onLine: { events.claude($0) }
                )
                if let failure = events.failure {
                    throw AIError.server(failure)
                }
                if !events.sentText {
                    guard let result = events.result else {
                        throw AIError.server(Self.failure("Claude Code", output))
                    }
                    continuation.yield(.text(result))
                }
            case .codex:
                let answer = directory.appendingPathComponent("answer.txt")
                var arguments = [
                    "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--json", "--output-last-message",
                    answer.path,
                    // The user's MCP servers start before every answer, and Tabula uses none of them: one that
                    // was slow to start held an answer for over a minute. An override works on every version.
                    "-c", "mcp_servers={}",
                ]
                // Codex shares a summary of its reasoning only when asked; suggestions while typing don't show it.
                if request.purpose != .inline {
                    arguments += ["-c", "model_reasoning_summary=\"detailed\""]
                }
                if !model.isEmpty {
                    arguments += ["--model", model]
                }
                if let effort {
                    arguments += ["-c", "model_reasoning_effort=\"\(effort)\""]
                }
                arguments.append("-")
                try (request.instructions + "\n\n" + request.prompt)
                    .write(to: prompt, atomically: true, encoding: .utf8)
                let output = try await ShellCommand.run(
                    script: Self.fromPromptFile,
                    arguments: [executable, prompt.path] + arguments,
                    directory: directory,
                    timeout: Defaults.AI.generateTimeout,
                    onLine: { events.codex($0) }
                )
                // Codex writes status messages between steps; the answer is the last message (also in the file).
                let final =
                    (try? String(contentsOf: answer, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? events.lastMessage
                if !events.sentText {
                    guard let final else {
                        throw AIError.server(events.failure.map { "Codex: \($0)" } ?? Self.failure("Codex", output))
                    }
                    continuation.yield(.text(final))
                }
            }
        }
    }

    /// Runs the tool (the first argument) with the prompt file (the second, an absolute path) as its standard input.
    /// The path is absolute because a shell profile may change directory before the command runs.
    static let fromPromptFile = #"prompt="$1"; shift; exec "$0" "$@" < "$prompt""#

    /// `claude -p` for one answer, with the user's own Claude Code setup kept out (#80): hooks (a SessionStart
    /// hook can add its own instructions or take long), MCP servers (each is started before the answer, and one
    /// that hangs kept the chat on Thinking), skills and slash commands, and saving the session. The account,
    /// model defaults and other settings still apply.
    static func claudeArguments(_ request: AIRequest, model: String, effort: String?) -> [String] {
        var arguments = [
            "-p", "--system-prompt", request.instructions, "--tools", "", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages",
            "--strict-mcp-config", "--settings", #"{"disableAllHooks": true}"#, "--disable-slash-commands",
            "--no-session-persistence",
        ]
        if !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort {
            arguments += ["--effort", effort]
        }
        return arguments
    }

    private static func failure(_ name: String, _ output: ShellCommand.Output) -> String {
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.status == ShellCommand.notFoundStatus {
            return "\(name) isn't installed, or isn't on your shell's PATH."
        }
        return detail.isEmpty
            ? "\(name) exited with status \(output.status)." : "\(name): \(detail.suffix(Defaults.toolErrorLength))"
    }
}

/// The tools' paths found so far, shared by every request.
private final class LocatedTools: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [CLIProvider.Tool: String] = [:]

    func path(for tool: CLIProvider.Tool) -> String? {
        lock.withLock { paths[tool] }
    }

    /// Records a found path; a tool not found is looked for again next time, in case it was just installed.
    func set(_ path: String?, for tool: CLIProvider.Tool) {
        lock.withLock { paths[tool] = path }
    }
}

/// Reads the agents' JSON lines into stream events.
final class CLIEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AIStream.Continuation
    private var textSent = false
    private var finalResult: String?
    private var error: String?
    /// Codex: the newest complete message; earlier ones were progress notes.
    private var message: String?

    init(_ continuation: AIStream.Continuation) { self.continuation = continuation }

    var sentText: Bool { lock.withLock { textSent } }
    var result: String? { lock.withLock { finalResult } }
    var failure: String? { lock.withLock { error } }
    var lastMessage: String? { lock.withLock { message } }

    private func yield(_ event: AIStreamEvent) {
        if case .text = event { lock.withLock { textSent = true } }
        continuation.yield(event)
    }

    private static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    /// `claude -p --output-format stream-json --include-partial-messages`: API stream events, then a result line.
    func claude(_ line: String) {
        guard let json = Self.object(line) else { return }
        switch json["type"] as? String {
        case "stream_event":
            let event = json["event"] as? [String: Any] ?? [:]
            guard event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any] else {
                return
            }
            switch delta["type"] as? String {
            case "thinking_delta": if let text = delta["thinking"] as? String { yield(.thinking(text)) }
            case "text_delta": if let text = delta["text"] as? String { yield(.text(text)) }
            default: break
            }
        case "result":
            let text = json["result"] as? String
            lock.withLock {
                if json["is_error"] as? Bool == true {
                    error = text ?? "Claude Code failed."
                } else {
                    finalResult = text
                }
            }
        default:
            break
        }
    }

    /// `codex exec --json`: completed items (reasoning, agent_message) in current versions; older versions sent
    /// `msg` objects with deltas. Messages before the last are progress notes, shown with the reasoning; the
    /// answer is sent at the end. Error events are kept but only matter when no answer comes (Codex reports
    /// retries it recovers from as errors too).
    func codex(_ line: String) {
        guard let json = Self.object(line) else { return }
        if let item = json["item"] as? [String: Any], json["type"] as? String == "item.completed" {
            switch item["type"] as? String {
            case "reasoning": if let text = item["text"] as? String { yield(.thinking(text + "\n\n")) }
            case "agent_message":
                guard let text = item["text"] as? String else { return }
                let previous = lock.withLock { () -> String? in
                    defer { message = text }
                    return message
                }
                if let previous {
                    yield(.thinking(previous + "\n\n"))
                }
            default: break
            }
            return
        }
        if json["type"] as? String == "turn.failed" || json["type"] as? String == "error" {
            let text = ((json["error"] as? [String: Any])?["message"] ?? json["message"]) as? String
            lock.withLock { error = text ?? "Codex failed." }
            return
        }
        guard let event = json["msg"] as? [String: Any] else { return }
        switch event["type"] as? String {
        case "agent_reasoning_delta": if let text = event["delta"] as? String { yield(.thinking(text)) }
        case "agent_message_delta": if let text = event["delta"] as? String { yield(.text(text)) }
        case "agent_message": if let text = event["message"] as? String { lock.withLock { message = text } }
        case "error": lock.withLock { error = event["message"] as? String ?? "Codex failed." }
        default: break
        }
    }
}
