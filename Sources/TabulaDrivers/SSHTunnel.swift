import Darwin
import Foundation
import TabulaFoundation
import TabulaSQL

/// A local port forwarded through `/usr/bin/ssh` to a database server, for as long as the tunnel lives.
///
/// The ssh process gets a fixed argument list (no shell parses it), ignores the user's ssh config (which can run
/// commands), authenticates with keys only, and trusts only host keys already in known_hosts. Its forward listens on
/// 127.0.0.1. ssh reports the forward ready with `ExitOnForwardFailure` and the port answering.
///
/// ssh doesn't exit with the app that started it, so a crashed or force-quit Tabula would leave the tunnel open.
/// ssh runs under a small /bin/sh watcher holding a pipe from Tabula: when the pipe closes, because the tunnel is
/// closed or Tabula is gone however it ended, the watcher stops ssh.
public actor SSHTunnel {
    public nonisolated let localPort: Int
    private let process: Process
    private let errors: Pipe
    /// Closing it stops ssh.
    private let lifeline: Pipe

    private init(localPort: Int, process: Process, errors: Pipe, lifeline: Pipe) {
        self.localPort = localPort
        self.process = process
        self.errors = errors
        self.lifeline = lifeline
    }

    /// Runs "$@" (ssh and its arguments, never parsed by the shell) and stops it when standard input closes.
    /// The watcher exits with ssh's status, and its reader goes with it.
    static let watcher = #"exec 3<&0; "$@" </dev/null 3<&- & child=$!; (read -r _ <&3; kill "$child") >/dev/null 2>&1 & reader=$!; wait "$child"; status=$?; kill "$reader" 2>/dev/null; exit "$status""#

    /// Opens a tunnel from 127.0.0.1 to `targetHost:targetPort` as seen from the SSH server.
    public static func open(_ ssh: SSHConfig, targetHost: String, targetPort: Int, timeout: Double) async throws -> SSHTunnel {
        var knownHosts: String?
        #if DEBUG
        // TABULA_DEBUG_SSH_KNOWN_HOSTS: a throwaway server's host key, so checks don't touch ~/.ssh/known_hosts.
        knownHosts = ProcessInfo.processInfo.environment["TABULA_DEBUG_SSH_KNOWN_HOSTS"]
        #endif
        return try await open(ssh, targetHost: targetHost, targetPort: targetPort, timeout: timeout, knownHosts: knownHosts)
    }

    /// `knownHosts` replaces ~/.ssh/known_hosts, for tests against a throwaway server.
    static func open(_ ssh: SSHConfig, targetHost: String, targetPort: Int, timeout: Double, knownHosts: String?) async throws -> SSHTunnel {
        if let problem = ssh.problem { throw DatabaseError(problem) }
        guard SSHConfig.isSafeName(targetHost), (1...65535).contains(targetPort) else {
            throw DatabaseError("The database host isn't valid for an SSH tunnel.")
        }
        var lastError: Error = DatabaseError("Couldn't open the SSH tunnel.")
        // The free port is found first and released for ssh to take; another program could take it in between,
        // so a forward that fails to bind is tried again on a new port.
        for _ in 0..<3 {
            let port = try freeLocalPort()
            do {
                return try await start(ssh, port: port, targetHost: targetHost, targetPort: targetPort, timeout: timeout,
                                       knownHosts: knownHosts)
            } catch let error as TunnelError where error.retryable {
                lastError = DatabaseError(error.message)
            } catch {
                throw error
            }
        }
        throw lastError
    }

    struct TunnelError: LocalizedError {
        var message: String
        var retryable: Bool
        var errorDescription: String? { message }
    }

    static func arguments(_ ssh: SSHConfig, localPort: Int, targetHost: String, targetPort: Int, timeout: Double,
                          knownHosts: String? = nil) -> [String] {
        var arguments = [
            "-F", "/dev/null", // the user's ssh config can run commands and add forwards
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ConnectTimeout=\(max(1, Int(timeout.rounded(.up))))",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):\(targetHost):\(targetPort)",
            "-p", String(ssh.port),
            "-l", ssh.user,
        ]
        if let knownHosts { arguments += ["-o", "UserKnownHostsFile=\(knownHosts)", "-o", "GlobalKnownHostsFile=/dev/null"] }
        if let identityFile = ssh.identityFile {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        // "--" ends the options, so the host can't be read as one.
        return arguments + ["--", ssh.host]
    }

    private static func start(_ ssh: SSHConfig, port: Int, targetHost: String, targetPort: Int, timeout: Double,
                              knownHosts: String?) async throws -> SSHTunnel {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watcher, "sh", "/usr/bin/ssh"]
            + arguments(ssh, localPort: port, targetHost: targetHost, targetPort: targetPort, timeout: timeout, knownHosts: knownHosts)
        var environment = ProcessInfo.processInfo.environment
        // Never pop up a password prompt; keys come from the agent (SSH_AUTH_SOCK) or the identity file.
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        environment.removeValue(forKey: "DISPLAY")
        process.environment = environment
        let lifeline = Pipe()
        process.standardInput = lifeline
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let collected = BoundedText()
        errors.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        process.terminationHandler = { live.remove($0.processIdentifier) }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        live.insert(process.processIdentifier, lifeline.fileHandleForWriting)
        let tunnel = SSHTunnel(localPort: port, process: process, errors: errors, lifeline: lifeline)

        do {
            let deadline = Date().addingTimeInterval(timeout + 2)
            while Date() < deadline {
                try Task.checkCancellation()
                if !process.isRunning {
                    errors.fileHandleForReading.readabilityHandler = nil
                    collected.append(errors.fileHandleForReading.readDataToEndOfFile())
                    let text = collected.text
                    let bindFailure = text.contains("Address already in use") || text.contains("cannot listen to port")
                    throw TunnelError(message: describe(text, ssh: ssh), retryable: bindFailure)
                }
                if isListening(port: port) { return tunnel }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw TunnelError(message: "The SSH server \(ssh.host) didn't answer within \(Int(timeout)) seconds.", retryable: false)
        } catch {
            await tunnel.close()
            throw error
        }
    }

    /// ssh's own message, shortened, with the usual causes explained.
    static func describe(_ stderr: String, ssh: SSHConfig) -> String {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Host key verification failed") || text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "SSH: the host key of \(ssh.host) isn't trusted. Connect once with ssh in Terminal to check and save it, then try again."
        }
        if text.contains("Permission denied") {
            return "SSH: \(ssh.user)@\(ssh.host) refused the key. Add the key to ssh-agent (ssh-add) or choose the key file."
        }
        let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ssh exited."
        return "SSH: \(last.prefix(Defaults.toolErrorLength))"
    }

    /// Stops ssh; the forward closes with it.
    public func close() {
        errors.fileHandleForReading.readabilityHandler = nil
        try? lifeline.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let process = process
        // ssh exits on SIGTERM; one that doesn't is killed shortly after.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    public var isAlive: Bool { process.isRunning }

    /// ssh processes still running. ssh doesn't exit with its parent, so quitting stops them here, synchronously,
    /// instead of relying on each window closing its connection on the way out.
    private static let live = LiveProcesses()

    /// Stops every tunnel at once; for when the app quits.
    /// Closing each tunnel's lifeline makes its watcher stop ssh.
    public static func terminateAll() {
        for lifeline in live.all { try? lifeline.close() }
    }

    private final class LiveProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var lifelines: [pid_t: FileHandle] = [:]

        func insert(_ pid: pid_t, _ lifeline: FileHandle) { lock.withLock { lifelines[pid] = lifeline } }
        func remove(_ pid: pid_t) { _ = lock.withLock { lifelines.removeValue(forKey: pid) } }
        var all: [FileHandle] { lock.withLock { Array(lifelines.values) } }
    }

    /// A port nothing listens on, found by binding port 0 on 127.0.0.1.
    static func freeLocalPort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw DatabaseError("Couldn't find a free local port for the SSH tunnel.") }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) }
        }
        guard bound == 0 else { throw DatabaseError("Couldn't find a free local port for the SSH tunnel.") }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard named == 0 else { throw DatabaseError("Couldn't find a free local port for the SSH tunnel.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// Whether something accepts connections on 127.0.0.1:`port`.
    static func isListening(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// The last few KB of ssh's error output, so a chatty server can't grow it without bound.
    private final class BoundedText: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ more: Data) {
            lock.withLock {
                data.append(more)
                if data.count > 8192 { data = data.suffix(8192) }
            }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

/// A database driver that owns the SSH tunnel it connects through, and closes it after the database.
public actor TunneledDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind
    public nonisolated var dialect: any QueryDialect { inner.dialect }
    public nonisolated var catalog: any DatabaseCatalog { inner.catalog }
    /// PostgreSQL's Stop opens its control connection through the same tunnel.
    public nonisolated var queryCancellation: QueryCancellationSupport { inner.queryCancellation }
    private let inner: any DatabaseDriver
    private let tunnel: SSHTunnel

    public init(_ inner: any DatabaseDriver, tunnel: SSHTunnel) {
        self.inner = inner
        self.kind = inner.kind
        self.tunnel = tunnel
    }

    private func checkTunnel() async throws {
        guard await tunnel.isAlive else { throw DatabaseError("The SSH tunnel closed. Reconnect to continue.") }
    }

    public func schemas() async throws -> [String] { try await checkTunnel(); return try await inner.schemas() }
    public func defaultSchema() async throws -> String { try await checkTunnel(); return try await inner.defaultSchema() }
    public func tables(in schema: String) async throws -> [TableRef] { try await checkTunnel(); return try await inner.tables(in: schema) }
    public func columns(of table: TableRef) async throws -> [ColumnInfo] { try await checkTunnel(); return try await inner.columns(of: table) }
    public func indexes(of table: TableRef) async throws -> [IndexInfo] { try await checkTunnel(); return try await inner.indexes(of: table) }
    public func execute(_ sql: String) async throws -> QueryResult { try await checkTunnel(); return try await inner.execute(sql) }
    public func queryEditTarget(for result: QueryResult) async throws -> QueryEditTarget? {
        try await checkTunnel()
        return try await inner.queryEditTarget(for: result)
    }
    public func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]] {
        try await checkTunnel()
        return try await inner.commitQueryEdits(edits, target: target)
    }

    public func close() async {
        await inner.close()
        await tunnel.close()
    }
}
