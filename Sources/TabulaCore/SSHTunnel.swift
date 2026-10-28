import Darwin
import Foundation

/// An SSH server that database traffic goes through, for servers reachable only from it (a bastion).
/// Keys come from ssh-agent or an identity file; no SSH password or passphrase is ever stored.
public struct SSHConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    /// A private key file; nil uses ssh-agent and the default keys.
    public var identityFile: String?

    public init(host: String = "", port: Int = 22, user: String = "", identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.identityFile = identityFile
    }

    /// What's wrong with these settings, or nil when they can be used. Checked again before every connection, since
    /// saved files can be edited by hand.
    public var problem: String? {
        if host.isEmpty { return "Enter the SSH host." }
        if !Self.isSafeName(host) { return "The SSH host isn't valid." }
        if !(1...65535).contains(port) { return "The SSH port must be between 1 and 65535." }
        if user.isEmpty { return "Enter the SSH user." }
        if !Self.isSafeName(user) { return "The SSH user isn't valid." }
        if let identityFile {
            let path = (identityFile as NSString).expandingTildeInPath
            if path.isEmpty || path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return "The SSH key path isn't valid."
            }
            if !FileManager.default.isReadableFile(atPath: path) { return "The SSH key file can't be read." }
        }
        return nil
    }

    /// Host names, IP addresses and user names, with nothing ssh could read as an option, a second host or part
    /// of a forward specification.
    static func isSafeName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first != "-" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return text.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}

/// A local port forwarded through `/usr/bin/ssh` to a database server, for as long as the tunnel lives.
///
/// The ssh process gets a fixed argument list (never a shell), ignores the user's ssh config (which can run
/// commands), authenticates with keys only, and trusts only host keys already in known_hosts. Its forward listens on
/// 127.0.0.1. ssh reports the forward ready with `ExitOnForwardFailure` and the port answering.
public actor SSHTunnel {
    public nonisolated let localPort: Int
    private let process: Process
    private let errors: Pipe

    private init(localPort: Int, process: Process, errors: Pipe) {
        self.localPort = localPort
        self.process = process
        self.errors = errors
    }

    /// Opens a tunnel from 127.0.0.1 to `targetHost:targetPort` as seen from the SSH server.
    public static func open(_ ssh: SSHConfig, targetHost: String, targetPort: Int, timeout: Double) async throws -> SSHTunnel {
        try await open(ssh, targetHost: targetHost, targetPort: targetPort, timeout: timeout, knownHosts: nil)
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments(ssh, localPort: port, targetHost: targetHost, targetPort: targetPort, timeout: timeout,
                                      knownHosts: knownHosts)
        var environment = ProcessInfo.processInfo.environment
        // Never pop up a password prompt; keys come from the agent (SSH_AUTH_SOCK) or the identity file.
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        environment.removeValue(forKey: "DISPLAY")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
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
        live.insert(process.processIdentifier)
        let tunnel = SSHTunnel(localPort: port, process: process, errors: errors)

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
        return "SSH: \(last.prefix(Defaults.AI.errorLength))"
    }

    /// Stops ssh; the forward closes with it.
    public func close() {
        errors.fileHandleForReading.readabilityHandler = nil
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
    public static func terminateAll() {
        for pid in live.all { kill(pid, SIGTERM) }
    }

    private final class LiveProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<pid_t> = []

        func insert(_ pid: pid_t) { _ = lock.withLock { pids.insert(pid) } }
        func remove(_ pid: pid_t) { _ = lock.withLock { pids.remove(pid) } }
        var all: [pid_t] { lock.withLock { Array(pids) } }
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
    /// PostgreSQL's Stop opens its control connection through the same tunnel.
    public nonisolated var queryCancellation: QueryCancellationSupport { inner.queryCancellation }
    private let inner: any DatabaseDriver
    private let tunnel: SSHTunnel

    init(_ inner: any DatabaseDriver, tunnel: SSHTunnel) {
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
