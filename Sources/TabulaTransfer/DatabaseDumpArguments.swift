import Darwin
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// The tools' command lines: arguments, environment and option files. Pure functions, so tests can check them.
extension DatabaseDump {
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
}
