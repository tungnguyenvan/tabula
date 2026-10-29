import Darwin
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Dumps and restores PostgreSQL and MySQL databases with the client tools installed on the Mac (`pg_dump`,
/// `pg_restore`, `psql`, `mysqldump`, `mysql`, or MariaDB's), as other clients do. Their output is what DBAs expect
/// and restore elsewhere; writing our own dump would miss sequences, extensions, routines and grants.
///
/// The tools run directly (never through a shell) with fixed arguments. Connection details go in the environment
/// (PostgreSQL) or a private option file (MySQL), never on the command line where other processes could read them.
public enum DatabaseDump {
    public enum Tool: String, Sendable, CaseIterable {
        case pgDump = "pg_dump"
        case pgRestore = "pg_restore"
        case psql
        case mysqldump
        case mysql

        /// MariaDB's names for the same tools.
        var alternatives: [String] {
            switch self {
            case .mysqldump: ["mariadb-dump"]
            case .mysql: ["mariadb"]
            default: []
            }
        }

        public var installHint: String {
            switch self {
            case .pgDump, .pgRestore, .psql:
                "Install PostgreSQL's client tools, for example with Homebrew (brew install libpq) or Postgres.app."
            case .mysqldump, .mysql:
                "Install MySQL's client tools, for example with Homebrew (brew install mysql-client), or MariaDB's (brew install mariadb)."
            }
        }
    }

    /// A tool found on this Mac.
    public struct Located: Sendable, Equatable {
        public var path: String
        /// The first line of `--version`.
        public var version: String
        /// Major version (PostgreSQL 18 → 18; MySQL 8.4 → 8).
        public var major: Int
        public var isMariaDB: Bool
    }

    public enum Content: String, Sendable, CaseIterable, Identifiable {
        case all, structure, data
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: "Structure and data"
            case .structure: "Structure only"
            case .data: "Data only"
            }
        }
    }

    public enum Format: String, Sendable, CaseIterable, Identifiable {
        /// A .sql script, restored with psql or mysql.
        case sql
        /// PostgreSQL's compressed archive, restored with pg_restore.
        case custom
        public var id: String { rawValue }
        public var fileExtension: String { self == .sql ? "sql" : "dump" }
    }

    public struct DumpOptions: Sendable {
        public var content: Content = .all
        public var format: Format = .sql
        /// DROP before each CREATE, so restoring replaces what is there.
        public var addDrop = false
        /// PostgreSQL: ALTER … OWNER and GRANT statements. Off by default, so a dump restores under another login.
        public var ownersAndPrivileges = false
        /// Only these tables; empty dumps the whole database.
        public var tables: [TableRef] = []
        /// MySQL: the server is MariaDB, so MariaDB's tools are preferred (and MySQL's for MySQL).
        public var serverIsMariaDB: Bool?
        public init() {}
    }

    public struct RestoreOptions: Sendable {
        /// PostgreSQL: all or nothing; a failed statement rolls back everything before it.
        public var singleTransaction = true
        /// PostgreSQL archives: skip ownership and grants, so the dump restores under another login.
        public var skipOwnersAndPrivileges = true
        /// PostgreSQL archives: drop what the archive creates before creating it. (Scripts carry their own DROPs.)
        public var dropExisting = false
        /// The target server's major version (PostgreSQL), to leave out settings it doesn't have.
        public var serverMajor: Int?
        /// PostgreSQL 17 added "SET transaction_timeout", which pg_dump and pg_restore 17 and later emit and older
        /// servers reject. An unknown version counts as older: leaving the setting out is safe on every server.
        public var serverHasTransactionTimeout: Bool {
            guard let serverMajor else {
                return false
            }
            return serverMajor >= 17
        }
        /// MySQL: the server is MariaDB, so MariaDB's tools are preferred (and MySQL's for MySQL).
        public var serverIsMariaDB: Bool?
        public init() {}
    }

    public struct Progress: Sendable, Equatable {
        /// Bytes written (dump) or read (restore) so far.
        public var bytes: Int64 = 0
        /// The file's size when restoring a script, so progress can be shown as a fraction.
        public var total: Int64?
        /// The tool's latest message, such as the table it is on.
        public var message: String = ""
        public init(bytes: Int64 = 0, total: Int64? = nil, message: String = "") {
            self.bytes = bytes
            self.total = total
            self.message = message
        }
    }

    public enum FileKind: Equatable, Sendable { case postgresArchive, script }

    // MARK: Running

    /// Dumps `database` to `file`. A failed or cancelled dump leaves no file behind.
    public static func dump(
        _ config: ConnectionConfig,
        password: String?,
        database: String,
        options: DumpOptions,
        to file: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        try await withEndpoint(config) { endpoint in
            let partial = file.deletingLastPathComponent()
                .appendingPathComponent(".\(file.lastPathComponent).tabula-partial")
            try? FileManager.default.removeItem(at: partial)
            defer { try? FileManager.default.removeItem(at: partial) }
            switch config.kind {
            case .postgres:
                let tool = try await required(.pgDump)
                let environment = try postgresEnvironment(
                    config,
                    database: database,
                    password: password,
                    endpoint: endpoint,
                    tool: tool
                )
                try await runTool(
                    tool,
                    .pgDump,
                    pgDumpArguments(options, file: partial),
                    environment: environment,
                    watching: partial,
                    progress: progress
                )
            case .mysql:
                let tool = try await required(.mysqldump, preferMariaDB: options.serverIsMariaDB)
                try await withOptionFile(mysqlOptionFile(config, password: password, tool: tool)) { optionFile in
                    // Unknown --help output: --column-statistics is left off, which works on every server.
                    let help = (try? await run(tool.path, ["--help"], environment: [:], timeout: 10).output) ?? ""
                    let arguments = mysqldumpArguments(
                        options,
                        optionFile: optionFile,
                        connection: mysqlConnectionArguments(config, endpoint: endpoint),
                        database: database,
                        file: partial,
                        tool: tool,
                        supportsColumnStatistics: help.contains("column-statistics")
                    )
                    try await runTool(
                        tool,
                        .mysqldump,
                        arguments,
                        environment: mysqlEnvironment(optionFile: optionFile),
                        watching: partial,
                        progress: progress
                    )
                }
            default:
                throw DatabaseError("Dumps are available for PostgreSQL and MySQL connections.")
            }
            // Replaced in one step, so a failed move never loses the file that was there.
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: file)
            }
        }
    }

    /// Restores `file` into `database`. Scripts run with psql or mysql, PostgreSQL archives with pg_restore.
    public static func restore(
        _ config: ConnectionConfig,
        password: String?,
        database: String,
        options: RestoreOptions,
        from file: URL,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let kind = try kind(of: file)
        try await withEndpoint(config) { endpoint in
            switch (config.kind, kind) {
            case (.postgres, .postgresArchive) where options.serverHasTransactionTimeout:
                let tool = try await required(.pgRestore)
                let environment = try postgresEnvironment(
                    config,
                    database: database,
                    password: password,
                    endpoint: endpoint,
                    tool: tool
                )
                try await runTool(
                    tool,
                    .pgRestore,
                    pgRestoreArguments(options, database: database, file: file),
                    environment: environment,
                    progress: progress
                )
            case (.postgres, .postgresArchive):
                try await restoreArchiveThroughPsql(
                    config,
                    password: password,
                    database: database,
                    options: options,
                    file: file,
                    endpoint: endpoint,
                    progress: progress
                )
            case (.postgres, .script):
                try PostgresScriptCheck.check(file)
                let tool = try await required(.psql)
                let environment = try postgresEnvironment(
                    config,
                    database: database,
                    password: password,
                    endpoint: endpoint,
                    tool: tool
                )
                // pg_dump 17 and later write "SET transaction_timeout = 0;" into every script, which older servers
                // reject as an unknown setting, stopping the restore at its first line.
                var unsupported: [Data] = []
                if !options.serverHasTransactionTimeout {
                    unsupported.append(Data("\nSET transaction_timeout = 0;\n".utf8))
                }
                // Checked again as it is sent, in case the file changed since.
                let ending = DatabaseDump.commit
                var trailer: (@Sendable () -> Data?)?
                if options.singleTransaction { trailer = { ending } }
                try await runTool(
                    tool,
                    .psql,
                    psqlArguments(),
                    environment: environment,
                    input: .file(file),
                    prefix: options.singleTransaction ? begin : Data(),
                    trailer: trailer,
                    dropFromHeader: unsupported,
                    checkScript: true,
                    progress: progress
                )
            case (.mysql, .script):
                try MySQLScriptCheck.check(file)
                let tool = try await required(.mysql, preferMariaDB: options.serverIsMariaDB)
                try await withOptionFile(mysqlOptionFile(config, password: password, tool: tool)) { optionFile in
                    // Whether the client can turn off shell commands is read from its help; a client whose help
                    // can't be read is reported, not taken for one that can't.
                    let help = try await run(tool.path, ["--help"], environment: [:], timeout: 10).output
                    let arguments = try mysqlArguments(
                        optionFile: optionFile,
                        connection: mysqlConnectionArguments(config, endpoint: endpoint),
                        database: database,
                        help: help
                    )
                    try await runTool(
                        tool,
                        .mysql,
                        arguments,
                        environment: mysqlEnvironment(optionFile: optionFile),
                        input: .file(file),
                        progress: progress
                    )
                }
            case (.mysql, .postgresArchive):
                throw DatabaseError(
                    "This is a PostgreSQL archive (pg_dump's custom format); it can't be restored into MySQL."
                )
            default:
                throw DatabaseError("Restoring is available for PostgreSQL and MySQL connections.")
            }
        }
    }

    /// pg_restore 17 and later send "SET transaction_timeout", which older servers reject. pg_restore turns the
    /// archive into a script instead, the setting is left out, and psql runs it.
    static func restoreArchiveThroughPsql(
        _ config: ConnectionConfig,
        password: String?,
        database: String,
        options: RestoreOptions,
        file: URL,
        endpoint: Endpoint,
        progress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        let tool = try await required(.pgRestore)
        let psql = try await required(.psql)
        let environment = try postgresEnvironment(
            config,
            database: database,
            password: password,
            endpoint: endpoint,
            tool: psql
        )
        let script = Pipe()
        let producerStatus = StatusGate()
        let producerArguments = pgRestoreScriptArguments(options, file: file)
        let producer = Task { () throws -> RunResult in
            do {
                let result = try await run(
                    tool.path,
                    producerArguments,
                    environment: [:],
                    timeout: nil,
                    standardOutput: script
                )
                producerStatus.finish(result.status)
                return result
            } catch {
                producerStatus.finish(-1)
                throw error
            }
        }
        // The script is checked line by line on its way to psql, so a psql command hidden in an archive stops
        // the restore before psql reads it. COMMIT follows only if pg_restore wrote the whole archive.
        var failure: Error?
        let ending = DatabaseDump.commit
        var trailer: (@Sendable () -> Data?)?
        if options.singleTransaction { trailer = { producerStatus.wait() == 0 ? ending : nil } }
        do {
            try await runTool(
                psql,
                .psql,
                psqlArguments(),
                environment: environment,
                input: .pipe(script.fileHandleForReading),
                prefix: options.singleTransaction ? begin : Data(),
                trailer: trailer,
                dropFromHeader: [Data("\nSET transaction_timeout = 0;\n".utf8)],
                checkScript: true,
                progress: progress
            )
        } catch {
            failure = error
        }
        // pg_restore stops once nobody reads its output; cancelling stops it as well.
        try? script.fileHandleForReading.close()
        // psql's error is the one to show; pg_restore is only stopped because of it.
        if let failure {
            producer.cancel()
            _ = try? await producer.value
            throw failure
        }
        let produced = try await withTaskCancellationHandler {
            try await producer.value
        } onCancel: {
            producer.cancel()
        }
        guard produced.status == 0 else {
            throw DatabaseError(describeFailure(produced.output, tool: tool, kind: .pgRestore, status: produced.status))
        }
    }

    /// Runs `body` against the database's address, through an SSH tunnel when the connection uses one.
    static func withEndpoint(_ config: ConnectionConfig, _ body: (Endpoint) async throws -> Void) async throws {
        guard let ssh = config.ssh else {
            return try await body(Endpoint(host: config.resolvedHost, port: config.port))
        }
        if config.kind == .mysql, config.tls == .verifyFull {
            throw DatabaseError(
                "MySQL's client tools can't verify the server's certificate through an SSH tunnel. Set TLS to Required for this connection to dump or restore it."
            )
        }
        let tunnel = try await SSHTunnel.open(
            ssh,
            targetHost: config.resolvedHost,
            targetPort: config.port,
            timeout: config.timeout
        )
        do {
            // PostgreSQL connects to the tunnel while checking the certificate against the real host name.
            let endpoint =
                config.kind == .postgres
                ? Endpoint(host: config.resolvedHost, port: tunnel.localPort, address: "127.0.0.1")
                : Endpoint(host: "127.0.0.1", port: tunnel.localPort)
            try await body(endpoint)
            await tunnel.close()
        } catch {
            await tunnel.close()
            throw error
        }
    }

    /// The option file lives in a directory only this user can read, and is deleted when the tool is done.
    static func withOptionFile(_ contents: String, _ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TabulaDump-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("client.cnf")
        guard
            FileManager.default.createFile(
                atPath: file.path,
                contents: Data(contents.utf8),
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw DatabaseError("Couldn't write the MySQL option file.")
        }
        try await body(file)
    }
}
