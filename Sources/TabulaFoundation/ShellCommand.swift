import Darwin
import Foundation

/// Runs a script in the user's login shell, with arguments passed separately (never interpolated).
public enum ShellCommand {
    /// The command was stopped because it ran past its timeout.
    public struct TimedOut: LocalizedError, Sendable {
        public let seconds: Double
        public var errorDescription: String? { "The command didn't finish within \(Int(seconds)) seconds." }
    }

    public struct Output: Sendable {
        public var stdout: String
        public var stderr: String
        public var status: Int32
    }

    /// What shells return when the command isn't found.
    public static let notFoundStatus: Int32 = 127

    /// `onLine` receives each line of standard output as soon as it is complete.
    public static func run(
        script: String,
        arguments: [String],
        input: String? = nil,
        directory: URL? = nil,
        timeout: Double,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l and -i load the same profile files as a Terminal window, where PATH is set up.
        process.arguments = ["-l", "-i", "-c", script] + arguments
        if let directory {
            process.currentDirectoryURL = directory
        }
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let collected = Collected(timeout: timeout, onLine: onLine)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collected.onDone = { continuation.resume(with: $0) }
                // Both pipes are drained while the process runs, so a chatty tool can't fill one and block.
                // Empty data is the end of the pipe.
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collected.closed(stdout: true)
                    } else {
                        collected.append(out: data)
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        collected.closed(stdout: false)
                    } else {
                        collected.append(err: data)
                    }
                }
                process.terminationHandler = { finished in
                    collected.exited(finished.terminationStatus)
                    // A background process the command started may hold the pipes open long after it finished
                    // (with the shell gone, it isn't stopped on timeout); don't wait for it.
                    DispatchQueue.global()
                        .asyncAfter(deadline: .now() + Defaults.processTerminateGrace) {
                            stdout.fileHandleForReading.readabilityHandler = nil
                            stderr.fileHandleForReading.readabilityHandler = nil
                            collected.complete()
                        }
                }
                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    collected.complete(throwing: error)
                    return
                }
                if let input {
                    // Written from a background queue so a large prompt can't block on a full pipe.
                    DispatchQueue.global()
                        .async {
                            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                            try? stdin.fileHandleForWriting.close()
                        }
                }
                // Stop the tool itself on timeout; abandoning it would leave it running in the background.
                DispatchQueue.global()
                    .asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        collected.timedOut = true
                        stop(process)
                    }
            }
        } onCancel: {
            stop(process)
        }
    }

    /// Interactive shells ignore SIGTERM. Note the commands the shell started, kill the shell first (so it
    /// can't start the next one), then stop those commands.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let shell = process.processIdentifier
        let children = childProcesses(of: shell)
        kill(shell, SIGKILL)
        for child in children {
            kill(child, SIGTERM)
        }
        // Whatever ignores SIGTERM is killed shortly after.
        DispatchQueue.global()
            .asyncAfter(deadline: .now() + Defaults.processTerminateGrace) {
                for child in children where kill(child, 0) == 0 {
                    kill(child, SIGKILL)
                }
            }
    }

    private static func childProcesses(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let output = Pipe()
        pgrep.standardOutput = output
        pgrep.standardError = FileHandle.nullDevice
        // Without pgrep, only the shell itself is stopped.
        guard (try? pgrep.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var expired = false
        private var status: Int32?
        private var stdoutClosed = false, stderrClosed = false, completed = false
        var onDone: (@Sendable (Result<Output, any Error>) -> Void)?
        private let onLine: (@Sendable (String) -> Void)?
        /// Standard output after the last complete line, for `onLine`.
        private var partialLine = Data()

        private let timeout: Double
        init(timeout: Double, onLine: (@Sendable (String) -> Void)?) {
            self.timeout = timeout
            self.onLine = onLine
        }

        var timedOut: Bool {
            get { lock.withLock { expired } }
            set { lock.withLock { expired = newValue } }
        }

        func exited(_ status: Int32) {
            lock.withLock { self.status = status }
            complete(onlyIfDrained: true)
        }

        func closed(stdout: Bool) {
            lock.withLock { if stdout { stdoutClosed = true } else { stderrClosed = true } }
            complete(onlyIfDrained: true)
        }

        /// Complete at EOF, or after a short grace period when an exited command's child keeps a pipe open.
        /// No thread blocks waiting for EOF; late reads and the grace timer may race, but finish only once.
        func complete(onlyIfDrained: Bool = false, throwing error: (any Error)? = nil) {
            let result: Result<Output, any Error>? = lock.withLock {
                guard !completed else { return nil }
                if onlyIfDrained && (status == nil || !stdoutClosed || !stderrClosed) {
                    return nil
                }
                completed = true
                if !partialLine.isEmpty {
                    onLine?(String(decoding: partialLine, as: UTF8.self))
                    partialLine = Data()
                }
                if let error {
                    return .failure(error)
                }
                if expired {
                    return .failure(TimedOut(seconds: timeout))
                }
                return .success(
                    Output(
                        stdout: String(decoding: out, as: UTF8.self),
                        stderr: String(decoding: err, as: UTF8.self),
                        status: status ?? -1
                    )
                )
            }
            if let result {
                onDone?(result)
            }
        }

        /// Lines are handed on while the lock is held: the pipe handlers and completion run on different
        /// threads, and the lines must keep their order.
        func append(out data: Data) {
            lock.withLock {
                guard !completed else { return }
                out.append(data)
                guard let onLine else { return }
                partialLine.append(data)
                while let newline = partialLine.firstIndex(of: UInt8(ascii: "\n")) {
                    onLine(String(decoding: partialLine[partialLine.startIndex..<newline], as: UTF8.self))
                    partialLine = Data(partialLine[partialLine.index(after: newline)...])
                }
            }
        }

        func append(err data: Data) { lock.withLock { if !completed { err.append(data) } } }
    }
}
