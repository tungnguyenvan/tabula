import Darwin
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Running a tool: its process, pipes, progress, cancellation and the tools still running when Tabula quits.
extension DatabaseDump {
    /// Runs a dump or restore tool to the end, reporting progress; cancelling the task stops it.
    enum Input {
        case file(URL)
        /// Another tool's output.
        case pipe(FileHandle)
    }

    static func runTool(
        _ tool: Located,
        _ kind: Tool,
        _ arguments: [String],
        environment: [String: String],
        input: Input? = nil,
        prefix: Data = Data(),
        trailer: (@Sendable () -> Data?)? = nil,
        dropFromHeader: [Data] = [],
        checkScript: Bool = false,
        watching output: URL? = nil,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        var total: Int64?
        if case .file(let url) = input {
            total = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
        }
        let state = ToolProgress(total: total, report: progress)
        let result = try await run(
            tool.path,
            arguments,
            environment: environment,
            timeout: nil,
            input: input,
            prefix: prefix,
            trailer: trailer,
            dropFromHeader: dropFromHeader,
            checkScript: checkScript,
            output: output,
            onLine: { state.line($0) },
            onRead: { state.read($0) }
        )
        guard result.status == 0 else {
            throw DatabaseError(describeFailure(result.output, tool: tool, kind: kind, status: result.status))
        }
    }

    /// The tool's last messages, with the usual causes explained.
    static func describeFailure(_ output: String, tool: Located, kind: Tool, status: Int32) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            .filter {
                !$0.hasPrefix("pg_dump: dumping") && !$0.hasPrefix("pg_restore: creating") && !$0.hasPrefix("-- ")
            }
        var text = lines.suffix(6).joined(separator: "\n")
        if text.isEmpty {
            text = "\(kind.rawValue) stopped (status \(status))."
        }
        if output.contains("server version mismatch") || output.contains("aborting because of server version mismatch")
        {
            text += "\n\nThe server is newer than \(kind.rawValue) \(tool.major) (\(tool.path)). \(kind.installHint)"
        }
        if output.contains("unrecognized configuration parameter \"transaction_timeout\"")
            || output.contains("invalid command \\restrict")
        {
            text +=
                "\n\nThe dump was made by a newer pg_dump than this \(kind.rawValue) understands. \(kind.installHint)"
        }
        return text
    }

    /// Reports progress no more than a few times a second.
    final class ToolProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var progress: Progress
        private var lastReport = Date.distantPast
        private let report: @Sendable (Progress) -> Void

        init(total: Int64?, report: @escaping @Sendable (Progress) -> Void) {
            self.progress = Progress(total: total)
            self.report = report
        }

        func line(_ text: String) { update { $0.message = text } }
        func read(_ bytes: Int64) { update { $0.bytes = bytes } }

        private func update(_ change: (inout Progress) -> Void) {
            let snapshot: Progress? = lock.withLock {
                change(&progress)
                guard Date().timeIntervalSince(lastReport) > 0.2 else { return nil }
                lastReport = Date()
                return progress
            }
            if let snapshot {
                report(snapshot)
            }
        }
    }

    struct RunResult {
        var status: Int32
        var output: String
    }

    /// Another tool's exit status, waited for from the thread feeding psql.
    final class StatusGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var status: Int32?
        func finish(_ value: Int32) {
            let first: Bool = lock.withLock {
                defer { if status == nil { status = value } }
                return status == nil
            }
            if first {
                semaphore.signal()
            }
        }
        func wait() -> Int32 {
            semaphore.wait()
            semaphore.signal()
            return lock.withLock { status ?? -1 }
        }
    }

    /// Runs `path` with `arguments` (no shell) and a clean environment plus `environment`. `input` is streamed to
    /// standard input; `output` is a file the tool writes, whose growing size is reported through `onRead`.
    /// `dropFromHeader`: lines removed from the first chunk of `input` (the script's header of settings).
    /// `prefix` goes to standard input before `input`; `trailer` is asked for what follows it once `input` has been
    /// read to the end without errors, and may block until it knows (nil sends nothing).
    static func run(
        _ path: String,
        _ arguments: [String],
        environment: [String: String],
        timeout: Double?,
        input: Input? = nil,
        prefix: Data = Data(),
        trailer: (@Sendable () -> Data?)? = nil,
        dropFromHeader: [Data] = [],
        checkScript: Bool = false,
        output: URL? = nil,
        standardOutput: Pipe? = nil,
        onLine: (@Sendable (String) -> Void)? = nil,
        onRead: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Only what the tools need: settings from the user's environment (PGSERVICE, MYSQL_HOST…) could send them
        // to another server.
        var base = ProcessInfo.processInfo.environment.filter { key, _ in
            ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains(key)
        }
        base["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = base.merging(environment) { _, new in new }
        let messages = Pipe()
        process.standardOutput = standardOutput ?? messages
        process.standardError = messages
        let reader: FileHandle?
        switch input {
        case .file(let url): reader = try FileHandle(forReadingFrom: url)
        case .pipe(let handle): reader = handle
        case nil: reader = nil
        }
        let stdin = Pipe()
        process.standardInput = reader == nil ? FileHandle.nullDevice : stdin

        let collected = OutputCollector(onLine: onLine)
        messages.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(data)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
                process.terminationHandler = { finished in
                    running.remove(finished)
                    messages.fileHandleForReading.readabilityHandler = nil
                    collected.append(messages.fileHandleForReading.availableData)
                    if let failure = collected.failure {
                        continuation.resume(throwing: failure)
                    } else if collected.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            returning: RunResult(status: finished.terminationStatus, output: collected.text)
                        )
                    }
                }
                do {
                    try process.run()
                } catch {
                    messages.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                collected.process = process
                running.insert(process)
                if let reader {
                    // Streamed from a background queue in chunks, so a large dump never sits in memory and progress
                    // follows what the tool has read.
                    DispatchQueue.global()
                        .async {
                            // A tool that exits early must not take Tabula down with SIGPIPE; the write fails instead.
                            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                            var sent: Int64 = 0
                            var first = true
                            var scanner = checkScript ? PostgresScriptCheck.Scanner() : nil
                            var carry = Data()
                            func write(_ data: Data) -> Bool {
                                guard !data.isEmpty else { return true }
                                do {
                                    try stdin.fileHandleForWriting.write(contentsOf: data)
                                    return true
                                } catch { return false }
                            }
                            // Clean means every byte of the input was read and passed on: only then may the trailer
                            // (COMMIT) follow. A read error, a refused line or a tool that stopped reading leaves it out.
                            var clean = write(prefix)
                            while clean, !collected.cancelled {
                                var chunk: Data
                                do {
                                    guard let read = try reader.read(upToCount: 1 << 20), !read.isEmpty else { break }
                                    chunk = read
                                } catch {
                                    collected.fail(
                                        DatabaseError("Couldn't read the dump: \(error.localizedDescription)")
                                    )
                                    clean = false
                                    break
                                }
                                let size = chunk.count
                                if first {
                                    first = false
                                    for line in dropFromHeader {
                                        if let range = chunk.range(of: line, in: 0..<min(chunk.count, 1 << 16)) {
                                            chunk.replaceSubrange(range, with: Data("\n".utf8))
                                        }
                                    }
                                }
                                if scanner != nil {
                                    // Only whole lines that passed the check reach the tool.
                                    carry.append(chunk)
                                    var start = carry.startIndex
                                    var checked = Data()
                                    do {
                                        while let newline = carry[start...].firstIndex(of: UInt8(ascii: "\n")) {
                                            try scanner?.line(carry[start..<newline])
                                            checked.append(carry[start...newline])
                                            start = carry.index(after: newline)
                                        }
                                    } catch {
                                        collected.fail(error)
                                        clean = false
                                        break
                                    }
                                    carry = Data(carry[start...])
                                    chunk = checked
                                }
                                guard write(chunk) else {
                                    clean = false
                                    break
                                }
                                sent += Int64(size)
                                onRead?(sent)
                            }
                            if clean, !carry.isEmpty, !collected.cancelled {
                                do {
                                    try scanner?.line(carry[...])
                                    clean = write(carry)
                                } catch {
                                    collected.fail(error)
                                    clean = false
                                }
                            }
                            if clean, !collected.cancelled, let ending = trailer?() {
                                _ = write(ending)
                            }
                            if case .file = input {
                                try? reader.close()
                            }
                            try? stdin.fileHandleForWriting.close()
                        }
                }
                if let output, let onRead {
                    DispatchQueue.global()
                        .async {
                            while process.isRunning {
                                if let size = try? FileManager.default.attributesOfItem(atPath: output.path)[.size]
                                    as? Int
                                {
                                    onRead(Int64(size))
                                }
                                Thread.sleep(forTimeInterval: 0.25)
                            }
                        }
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { collected.stop() }
                }
            }
        } onCancel: {
            collected.stop()
        }
    }

    /// Tools running now, stopped when Tabula quits so none goes on dumping or restoring without it.
    static let running = RunningTools()

    /// Stops every dump and restore; for when the app quits. A restore in one transaction is rolled back.
    public static func terminateAll() {
        for process in running.all where process.isRunning {
            process.terminate()
        }
    }

    final class RunningTools: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [ObjectIdentifier: Process] = [:]
        func insert(_ process: Process) { lock.withLock { processes[ObjectIdentifier(process)] = process } }
        func remove(_ process: Process) {
            _ = lock.withLock { processes.removeValue(forKey: ObjectIdentifier(process)) }
        }
        var all: [Process] { lock.withLock { Array(processes.values) } }
    }

    /// Output kept for error messages (the last few KB), split into lines for progress.
    final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var partial = Data()
        private var stopped = false
        private let onLine: (@Sendable (String) -> Void)?
        var process: Process? {
            get { lock.withLock { storedProcess } }
            set {
                lock.withLock { storedProcess = newValue }
                if cancelled {
                    stop()
                }
            }
        }
        private var storedProcess: Process?

        init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

        var cancelled: Bool { lock.withLock { stopped } }
        private var storedFailure: Error?
        var failure: Error? { lock.withLock { storedFailure } }

        /// Stops the tool because of `error`, which the run then throws.
        func fail(_ error: Error) {
            lock.withLock { storedFailure = error }
            stop()
        }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

        func append(_ more: Data) {
            guard !more.isEmpty else { return }
            let lines: [String] = lock.withLock {
                data.append(more)
                if data.count > 16_384 {
                    data = data.suffix(16_384)
                }
                partial.append(more)
                var complete: [String] = []
                while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                    complete.append(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
                    partial = Data(partial[partial.index(after: newline)...])
                }
                if partial.count > 4096 {
                    partial = Data()
                }
                return complete
            }
            if let onLine {
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    onLine(line)
                }
            }
        }

        /// SIGTERM, then SIGKILL for a tool that doesn't stop.
        func stop() {
            let process: Process? = lock.withLock {
                stopped = true
                return storedProcess
            }
            guard let process, process.isRunning else { return }
            process.terminate()
            DispatchQueue.global()
                .asyncAfter(deadline: .now() + 3) {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
        }
    }
}
