import AppKit
import Foundation
import Observation
import TabulaFoundation
import TabulaRedis

/// The redis-cli style console.
@MainActor @Observable
final class RedisConsoleModel {
    struct Entry: Identifiable {
        let id = UUID()
        let prompt: String
        let command: String
        let output: String
        let isError: Bool
    }

    let config: ConnectionConfig
    var driver: RedisDriver?
    weak var workspace: RedisWorkspaceModel?
    private(set) var entries: [Entry] = []
    var input = ""
    private(set) var running = false
    private var history: [String] = []
    private var historyIndex: Int?

    init(config: ConnectionConfig) { self.config = config }

    var prompt: String {
        let database = workspace?.database ?? 0
        return "\(config.host):\(config.port)" + (database == 0 ? "" : "[\(database)]") + ">"
    }

    func run() async {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !running, let driver else { return }
        let prompt = self.prompt
        input = ""
        historyIndex = nil
        if history.last != line {
            history.append(line)
        }

        if line.lowercased() == "clear" {
            entries = []
            return
        }
        let arguments: [[UInt8]]
        do {
            arguments = try RedisCommandLine.parse(line)
        } catch {
            entries.append(
                Entry(
                    prompt: prompt,
                    command: line,
                    output: "Invalid argument(s): \(error.localizedDescription)",
                    isError: true
                )
            )
            return
        }
        if let refusal = RedisCommandLine.refusal(for: arguments) {
            entries.append(Entry(prompt: prompt, command: line, output: refusal, isError: true))
            return
        }
        if RedisCommandLine.isDestructive(arguments)
            || (config.tag == .production && !RedisCommandLine.isReadOnly(arguments))
        {
            guard confirm(line) else {
                entries.append(Entry(prompt: prompt, command: line, output: "Cancelled.", isError: true))
                return
            }
        }

        running = true
        defer { running = false }
        do {
            let reply = try await driver.send(arguments)
            var isError = false
            if case .error = reply {
                isError = true
            }
            entries.append(Entry(prompt: prompt, command: line, output: reply.formatted(), isError: isError))
            let database = await driver.database
            await workspace?.databaseChanged(to: database)
        } catch {
            entries.append(Entry(prompt: prompt, command: line, output: error.localizedDescription, isError: true))
        }
    }

    private func confirm(_ line: String) -> Bool {
        Confirmation.ask(
            "Run “\(line.prefix(120))”?",
            detail: config.tag == .production
                ? "This is a PRODUCTION connection." : "This command can delete or change a lot of data.",
            action: "Run"
        )
    }

    func historyUp() {
        guard !history.isEmpty else { return }
        let index = max(0, (historyIndex ?? history.count) - 1)
        historyIndex = index
        input = history[index]
    }

    func historyDown() {
        guard let index = historyIndex else { return }
        if index + 1 < history.count {
            historyIndex = index + 1
            input = history[index + 1]
        } else {
            historyIndex = nil
            input = ""
        }
    }

    func clear() { entries = [] }
}
