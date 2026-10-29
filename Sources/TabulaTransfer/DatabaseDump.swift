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

    // MARK: Finding the tools

    /// Directories the tools are installed in, besides the login shell's PATH: Postgres.app and Homebrew, including
    /// keg-only formulae (libpq, mysql-client) that aren't linked onto the PATH.
    static func candidateDirectories(for tool: Tool) -> [String] {
        let fm = FileManager.default
        func versions(_ parent: String, prefix: String, suffix: String = "/bin") -> [String] {
            ((try? fm.contentsOfDirectory(atPath: parent)) ?? [])
                .filter { $0.hasPrefix(prefix) }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(parent)/\($0)\(suffix)" }
        }
        var directories: [String] = []
        for brew in ["/opt/homebrew", "/usr/local"] {
            switch tool {
            case .pgDump, .pgRestore, .psql:
                directories += ["\(brew)/opt/libpq/bin"] + versions("\(brew)/opt", prefix: "postgresql")
            case .mysqldump, .mysql:
                directories +=
                    ["\(brew)/opt/mysql-client/bin"] + versions("\(brew)/opt", prefix: "mysql-client@")
                    + ["\(brew)/opt/mysql/bin", "\(brew)/opt/mariadb/bin"]
            }
            directories.append("\(brew)/bin")
        }
        if [.pgDump, .pgRestore, .psql].contains(tool) {
            directories = versions("/Applications/Postgres.app/Contents/Versions", prefix: "") + directories
        }
        return directories
    }

    /// The newest copy of `tool` on this Mac, or nil when there is none. pg_dump must be at least as new as the
    /// server, so among several installs the newest is the one that can dump the most servers.
    /// `preferMariaDB`: among MySQL-family tools, those of the server's own kind come first, whatever their version.
    public static func locate(_ tool: Tool, preferMariaDB: Bool? = nil) async -> Located? {
        var paths: [String] = []
        for name in [tool.rawValue] + tool.alternatives {
            paths += candidateDirectories(for: tool).map { "\($0)/\(name)" }
            if let output = try? await ShellCommand.run(script: #"command -v "$0""#, arguments: [name], timeout: 10),
                let path = output.stdout.split(whereSeparator: \.isNewline).last.map(String.init), path.hasPrefix("/")
            {
                paths.append(path)
            }
        }
        var seen = Set<String>()
        var found: [Located] = []
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let real = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(real).inserted, let located = await describe(path) else { continue }
            found.append(located)
        }
        if let preferMariaDB, found.contains(where: { $0.isMariaDB == preferMariaDB }) {
            found = found.filter { $0.isMariaDB == preferMariaDB }
        }
        return found.max { ($0.major, $0.version) < ($1.major, $1.version) }
    }

    static func describe(_ path: String) async -> Located? {
        guard let result = try? await run(path, ["--version"], environment: [:], timeout: 10), result.status == 0 else {
            return nil
        }
        var line = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // mysql prints its own path first ("/opt/…/bin/mysql  Ver 9.4.0 …"); the name is enough to show.
        if line.hasPrefix(path) {
            line = (path as NSString).lastPathComponent + line.dropFirst(path.count)
        }
        guard let major = majorVersion(line) else { return nil }
        return Located(path: path, version: line, major: major, isMariaDB: line.contains("MariaDB"))
    }

    /// "pg_dump (PostgreSQL) 18.6" → 18; "mysqldump  Ver 8.4.3 for macos" → 8;
    /// "mysqldump  Ver 10.19 Distrib 10.11.6-MariaDB" → 10 (the MariaDB version).
    static func majorVersion(_ line: String) -> Int? {
        let source = line.range(of: "Distrib ").map { String(line[$0.upperBound...]) } ?? line
        let pattern = line.contains("Ver ") && !line.contains("Distrib ") ? #"Ver (\d+)"# : #"(\d+)(\.\d+)*"#
        guard let match = source.range(of: pattern, options: .regularExpression) else { return nil }
        let digits = source[match].drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits)
    }

    /// What a dump file holds, from its first bytes: pg_dump's archives start with "PGDMP".
    public static func kind(of file: URL) throws -> FileKind {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 5) ?? Data()
        return head == Data("PGDMP".utf8) ? .postgresArchive : .script
    }

    // MARK: Arguments

    /// Where the tool connects. Through SSH it's the tunnel's local port, while TLS still checks the real host name.
    struct Endpoint {
        var host: String
        var port: Int
        /// The address to connect to instead of resolving `host` (the SSH tunnel), PostgreSQL only.
        var address: String?
    }

    static func postgresEnvironment(
        _ config: ConnectionConfig,
        database: String,
        password: String?,
        endpoint: Endpoint,
        tool: Located
    ) throws -> [String: String] {
        var environment = [
            "PGHOST": endpoint.host, "PGPORT": String(endpoint.port), "PGUSER": config.user, "PGDATABASE": database,
            "PGAPPNAME": Defaults.applicationName, "PGCONNECT_TIMEOUT": String(Int(config.timeout.rounded(.up))),
        ]
        if let address = endpoint.address {
            environment["PGHOSTADDR"] = address
        }
        if let password, !password.isEmpty {
            environment["PGPASSWORD"] = password
        }
        switch config.tls {
        case .disable: environment["PGSSLMODE"] = "disable"
        case .require: environment["PGSSLMODE"] = "require"
        case .verifyFull:
            // The certificates macOS trusts, as Tabula's own connection uses; libpq reads them from version 16.
            guard tool.major >= 16 else {
                throw DatabaseError(
                    "Verify certificate needs PostgreSQL client tools 16 or later (found \(tool.major)). \(Tool.pgDump.installHint)"
                )
            }
            environment["PGSSLMODE"] = "verify-full"
            environment["PGSSLROOTCERT"] = "system"
        }
        return environment
    }

    static func pgDumpArguments(_ options: DumpOptions, file: URL) -> [String] {
        var arguments = [
            "--no-password", "--verbose", "--format=\(options.format == .custom ? "custom" : "plain")",
            "--file=\(file.path)",
        ]
        switch options.content {
        case .all: break
        case .structure: arguments.append("--schema-only")
        case .data: arguments.append("--data-only")
        }
        // An archive keeps no DROPs; pg_restore adds them when asked.
        if options.addDrop, options.content != .data, options.format == .sql {
            arguments += ["--clean", "--if-exists"]
        }
        if !options.ownersAndPrivileges {
            arguments += ["--no-owner", "--no-privileges"]
        }
        // Quoted names are matched literally, not as patterns, and keep their case.
        arguments += options.tables.map { "--table=\(quotedPattern($0.schema)).\(quotedPattern($0.name))" }
        return arguments
    }

    static func quotedPattern(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func psqlArguments() -> [String] {
        // The script comes on standard input, so progress can be counted; ~/.psqlrc is not read.
        // Query results (pg_dump's SELECT set_config…) are thrown away; errors still come on standard error.
        ["--no-psqlrc", "--no-password", "--quiet", "--output=/dev/null", "--set=ON_ERROR_STOP=1"]
    }

    /// One transaction, opened and committed by Tabula rather than psql's --single-transaction: COMMIT is sent only
    /// after the whole script was read and checked, so a dump cut short (a read error, pg_restore failing midway,
    /// Tabula quitting) ends without COMMIT and the server rolls everything back.
    static let begin = Data("BEGIN;\n".utf8)
    static let commit = Data("\nCOMMIT;\n".utf8)

    /// pg_restore writing the archive as a script on standard output, for psql.
    static func pgRestoreScriptArguments(_ options: RestoreOptions, file: URL) -> [String] {
        var arguments = ["--file=-"]
        if options.dropExisting {
            arguments += ["--clean", "--if-exists"]
        }
        if options.skipOwnersAndPrivileges {
            arguments += ["--no-owner", "--no-privileges"]
        }
        return arguments + [file.path]
    }

    static func pgRestoreArguments(_ options: RestoreOptions, database: String, file: URL) -> [String] {
        var arguments = ["--no-password", "--verbose", "--exit-on-error", "--dbname=dbname=\(conninfoValue(database))"]
        if options.singleTransaction {
            arguments.append("--single-transaction")
        }
        if options.dropExisting {
            arguments += ["--clean", "--if-exists"]
        }
        if options.skipOwnersAndPrivileges {
            arguments += ["--no-owner", "--no-privileges"]
        }
        return arguments + [file.path]
    }

    /// A libpq connection string value: quoted, with ' and \ escaped.
    static func conninfoValue(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// The only option file the tool reads (`--defaults-file`): the password and TLS settings, kept off the command
    /// line. The user's ~/.my.cnf is not read, so it can't send the password to another server.
    static func mysqlOptionFile(_ config: ConnectionConfig, password: String?, tool: Located) -> String {
        // "loose-": mysqldump has no connect-timeout, and an unknown option would stop it.
        var lines = ["[client]", "loose-connect-timeout=\(Int(config.timeout.rounded(.up)))"]
        if let password, !password.isEmpty {
            lines.append("password=\(optionValue(password))")
        }
        switch (config.tls, tool.isMariaDB) {
        case (.disable, false): lines.append("ssl-mode=DISABLED")
        case (.require, false): lines.append("ssl-mode=REQUIRED")
        case (.verifyFull, false): lines += ["ssl-mode=VERIFY_IDENTITY", "ssl-ca=/etc/ssl/cert.pem"]
        case (.disable, true): lines.append("skip-ssl")
        // MariaDB 11.4 started verifying by default; older clients don't know the option, which "loose-" allows.
        case (.require, true): lines += ["ssl", "loose-disable-ssl-verify-server-cert"]
        case (.verifyFull, true): lines += ["ssl", "ssl-verify-server-cert", "ssl-ca=/etc/ssl/cert.pem"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Where to connect, on the command line after the option file so nothing else overrides it. None is secret.
    static func mysqlConnectionArguments(_ config: ConnectionConfig, endpoint: Endpoint) -> [String] {
        ["--protocol=TCP", "--host=\(endpoint.host)", "--port=\(endpoint.port)", "--user=\(config.user)"]
    }

    /// Keeps the client from reading login paths saved with mysql_config_editor, which are read last and could
    /// replace the host or password.
    static func mysqlEnvironment(optionFile: URL) -> [String: String] {
        [
            "MYSQL_TEST_LOGIN_FILE": optionFile.deletingLastPathComponent().appendingPathComponent("none.mylogin.cnf")
                .path
        ]
    }

    /// A quoted option file value; MySQL reads \\, \" and \n escapes inside quotes.
    static func optionValue(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func mysqldumpArguments(
        _ options: DumpOptions,
        optionFile: URL,
        connection: [String],
        database: String,
        file: URL,
        tool: Located,
        supportsColumnStatistics: Bool
    ) -> [String] {
        // --defaults-file must come first.
        var arguments =
            ["--defaults-file=\(optionFile.path)"] + connection + [
                "--verbose", "--single-transaction", "--routines",
                "--triggers", "--no-tablespaces", "--hex-blob", "--default-character-set=utf8mb4",
                "--result-file=\(file.path)",
            ]
        if !tool.isMariaDB {
            arguments.append("--set-gtid-purged=OFF")
        }
        // MySQL 8's mysqldump otherwise asks for column statistics that MariaDB and older servers don't have.
        if supportsColumnStatistics {
            arguments.append("--skip-column-statistics")
        }
        switch options.content {
        case .all: break
        case .structure: arguments.append("--no-data")
        case .data: arguments.append("--no-create-info")
        }
        arguments.append(options.addDrop ? "--add-drop-table" : "--skip-add-drop-table")
        // "--" ends the options, so no name can be read as one.
        return arguments + ["--", database] + options.tables.map(\.name)
    }

    /// The script can't use the client's own commands: no `system` (run commands on this Mac), `tee` (write files),
    /// `source` (read files), `connect` (another server); --binary-mode leaves only `delimiter` and `charset`, which
    /// dumps use. `LOAD DATA LOCAL` can't read local files either.
    static func mysqlArguments(optionFile: URL, connection: [String], database: String, help: String) throws -> [String]
    {
        var arguments =
            ["--defaults-file=\(optionFile.path)"] + connection
            + [
                "--default-character-set=utf8mb4", "--batch", "--binary-mode", "--local-infile=0",
                "--database=\(database)",
            ]
        if help.contains("system-command") {
            arguments.append("--skip-system-command")
        } else if help.contains("--sandbox") {
            arguments.append("--sandbox")
        } else {
            throw DatabaseError(
                "This mysql client can't be stopped from running shell commands found in a script. Update it to restore here. \(Tool.mysql.installHint)"
            )
        }
        return arguments
    }

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
                    let help = (try? await run(tool.path, ["--help"], environment: [:], timeout: 10).output) ?? ""
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

    static func required(_ tool: Tool, preferMariaDB: Bool? = nil) async throws -> Located {
        guard let located = await locate(tool, preferMariaDB: preferMariaDB) else {
            // Stopped while looking: the tool may well be there.
            try Task.checkCancellation()
            throw DatabaseError("\(tool.rawValue) isn't installed. \(tool.installHint)")
        }
        return located
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
