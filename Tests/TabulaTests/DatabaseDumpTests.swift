import XCTest

@testable import TabulaFoundation
@testable import TabulaMySQL
@testable import TabulaPostgres
@testable import TabulaTransfer

final class DatabaseDumpTests: XCTestCase {
    private let postgres18 = DatabaseDump.Located(
        path: "/x/pg_dump",
        version: "pg_dump (PostgreSQL) 18.6",
        major: 18,
        isMariaDB: false
    )
    private let mysql = DatabaseDump.Located(
        path: "/x/mysqldump",
        version: "mysqldump  Ver 8.4.3 for macos",
        major: 8,
        isMariaDB: false
    )

    func testVersions() {
        XCTAssertEqual(DatabaseDump.majorVersion("pg_dump (PostgreSQL) 18.6"), 18)
        XCTAssertEqual(DatabaseDump.majorVersion("pg_dump (PostgreSQL) 14.12 (Homebrew)"), 14)
        XCTAssertEqual(DatabaseDump.majorVersion("mysqldump  Ver 8.4.3 for macos15.0 on arm64 (Homebrew)"), 8)
        XCTAssertEqual(DatabaseDump.majorVersion("mysqldump  Ver 26.10.0 for macos26.6 on arm64 (Homebrew)"), 26)
        XCTAssertEqual(
            DatabaseDump.majorVersion("mysqldump  Ver 10.19 Distrib 10.11.6-MariaDB, for osx10.19 (arm64)"),
            10
        )
        XCTAssertEqual(
            DatabaseDump.majorVersion("mariadb-dump from 11.4.2-MariaDB, client 10.19 for osx10.19 (arm64)"),
            11
        )
    }

    func testPostgresArgumentsKeepSecretsOffTheCommandLine() throws {
        var options = DatabaseDump.DumpOptions()
        options.tables = [TableRef(schema: "Sales", name: "order\"s")]
        options.addDrop = true
        let file = URL(fileURLWithPath: "/tmp/out.sql")
        let arguments = DatabaseDump.pgDumpArguments(options, file: file)
        XCTAssertTrue(arguments.contains("--table=\"Sales\".\"order\"\"s\""))
        XCTAssertTrue(arguments.contains("--clean") && arguments.contains("--if-exists"))
        XCTAssertTrue(arguments.contains("--no-owner"))
        let config = ConnectionConfig(kind: .postgres, host: "db.example.com", user: "app", tls: .verifyFull)
        let environment = try DatabaseDump.postgresEnvironment(
            config,
            database: "shop",
            password: "s3cret",
            endpoint: .init(host: "db.example.com", port: 5432, address: "127.0.0.1"),
            tool: postgres18
        )
        XCTAssertEqual(environment["PGPASSWORD"], "s3cret")
        XCTAssertEqual(environment["PGHOSTADDR"], "127.0.0.1")
        XCTAssertEqual(environment["PGSSLROOTCERT"], "system")
        XCTAssertFalse(arguments.joined().contains("s3cret"))
        var old = postgres18
        old.major = 15
        XCTAssertThrowsError(
            try DatabaseDump.postgresEnvironment(
                config,
                database: "shop",
                password: nil,
                endpoint: .init(host: "h", port: 1),
                tool: old
            )
        )
        XCTAssertEqual(
            DatabaseDump.pgRestoreArguments(.init(), database: "a b'c", file: file).first { $0.hasPrefix("--dbname=") },
            #"--dbname=dbname='a b\'c'"#
        )
    }

    func testMySQLArguments() throws {
        let config = ConnectionConfig(kind: .mysql, host: "db", user: "app", tls: .require)
        let option = DatabaseDump.mysqlOptionFile(config, password: "p\"w\\d", tool: mysql)
        XCTAssertTrue(option.contains(#"password="p\"w\\d""#))
        XCTAssertTrue(option.contains("ssl-mode=REQUIRED"))
        let file = URL(fileURLWithPath: "/tmp/o.cnf")
        var options = DatabaseDump.DumpOptions()
        options.tables = [TableRef(schema: "shop", name: "-orders")]
        let arguments = DatabaseDump.mysqldumpArguments(
            options,
            optionFile: file,
            connection: ["--host=db"],
            database: "shop",
            file: URL(fileURLWithPath: "/tmp/d.sql"),
            tool: mysql,
            supportsColumnStatistics: true
        )
        XCTAssertEqual(arguments.first, "--defaults-file=/tmp/o.cnf")
        XCTAssertEqual(Array(arguments.suffix(3)), ["--", "shop", "-orders"])
        XCTAssertTrue(arguments.contains("--set-gtid-purged=OFF"))
        XCTAssertFalse(arguments.joined().contains("p\"w"))
        let restore = try DatabaseDump.mysqlArguments(
            optionFile: file,
            connection: [],
            database: "shop",
            help: "--system-command"
        )
        XCTAssertTrue(restore.contains("--skip-system-command"))
        XCTAssertTrue(restore.contains("--local-infile=0"))
        XCTAssertThrowsError(
            try DatabaseDump.mysqlArguments(optionFile: file, connection: [], database: "shop", help: "")
        )
    }

    func testScriptCheckRefusesPsqlCommands() {
        let safe = """
            \\restrict abc123
            SET standard_conforming_strings = on;
            CREATE FUNCTION f() RETURNS text AS $body$ SELECT '\\! not a command' $body$ LANGUAGE sql;
            INSERT INTO t VALUES ('a\\b', E'it\\'s', "x\\y"); -- \\! in a comment
            /* \\! /* nested */ still a comment */
            COPY public.t (a, b) FROM stdin;
            \\N\t\\!looks like a command but is data
            \\.
            SELECT $1, $$\\x$$;
            \\unrestrict abc123
            """
        XCTAssertNoThrow(try PostgresScriptCheck.check(text: safe))
        for bad in [
            "\\! rm -rf ~", "SELECT 1; \\! id", "\\copy t to '/tmp/x'", "\\o /tmp/x", "\\i other.sql",
            "\\connect other", "SELECT 'a'\\gexec", "SELECT E'\\'' \\! id", "COPY t FROM stdin;\n1\n\\.\n\\! id",
        ] {
            XCTAssertThrowsError(try PostgresScriptCheck.check(text: bad), bad)
        }
    }

    func testScriptCheckClosesReviewBypasses() {
        for bad in [
            "\\restrict abc \\! id", "-- note\r\\! id", "SELECT a$'x' \\! id", "SELECT 1; -- x\u{0}y",
            "SET standard_conforming_strings = off;", "SET client_encoding = 'SJIS';", "SET NAMES 'BIG5';",
        ] {
            XCTAssertThrowsError(try PostgresScriptCheck.check(text: bad), bad.debugDescription)
        }
        XCTAssertNoThrow(
            try PostgresScriptCheck.check(
                text: "SET client_encoding = 'UTF8';\nSET standard_conforming_strings = on;\n\\restrict k1\r"
            )
        )
        XCTAssertThrowsError(try MySQLScriptCheck.check(text: "INSERT INTO t VALUES (1);\nUSE `other`;"))
        XCTAssertThrowsError(try MySQLScriptCheck.check(text: "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `x`;"))
        XCTAssertNoThrow(
            try MySQLScriptCheck.check(text: "DROP TABLE IF EXISTS `t`;\nINSERT INTO `t` VALUES ('USE x');")
        )
    }

    func testFileKind() throws {
        let directory = FileManager.default.temporaryDirectory
        let archive = directory.appendingPathComponent("k-\(UUID()).dump")
        let script = directory.appendingPathComponent("k-\(UUID()).sql")
        try Data("PGDMP\u{1}".utf8).write(to: archive)
        try Data("SELECT 1;".utf8).write(to: script)
        defer {
            try? FileManager.default.removeItem(at: archive)
            try? FileManager.default.removeItem(at: script)
        }
        XCTAssertEqual(try DatabaseDump.kind(of: archive), .postgresArchive)
        XCTAssertEqual(try DatabaseDump.kind(of: script), .script)
    }

    // MARK: Against the disposable test containers

    private func temporaryFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tabula-dump-\(UUID().uuidString).\(ext)")
    }

    func testPostgresDumpAndRestoreBothFormats() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"] == "55432" else {
            throw XCTSkip("TABULA_TEST_PG_PORT=55432 not set")
        }
        guard let tool = await DatabaseDump.locate(.pgDump), tool.major >= 16 else {
            throw XCTSkip("pg_dump 16+ not installed")
        }
        let config = ConnectionConfig(
            kind: .postgres,
            host: "127.0.0.1",
            port: 55432,
            user: "tabula",
            database: "tabula"
        )
        let driver = try await PostgresDriver.connect(config, password: "tabula")
        let table = "dump_\(UUID().uuidString.prefix(8).lowercased())"
        let target = "restore_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await driver.execute("CREATE TABLE public.\(table) (id int PRIMARY KEY, label text)")
        _ = try await driver.execute("INSERT INTO public.\(table) VALUES (1, 'it''s'), (2, E'back\\\\slash')")
        _ = try await driver.execute("CREATE DATABASE \(target)")
        try await runThenClean(
            driver,
            cleanup: ["DROP TABLE public.\(table)", "DROP DATABASE \(target) WITH (FORCE)"]
        ) {
            for format in DatabaseDump.Format.allCases {
                let file = temporaryFile(format.fileExtension)
                defer { try? FileManager.default.removeItem(at: file) }
                var options = DatabaseDump.DumpOptions()
                options.format = format
                options.tables = [TableRef(schema: "public", name: table)]
                options.addDrop = true
                let reports = Reports()
                try await DatabaseDump.dump(config, password: "tabula", database: "tabula", options: options, to: file)
                {
                    reports.add($0)
                }
                XCTAssertGreaterThan(
                    (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0,
                    0
                )
                var restoreOptions = DatabaseDump.RestoreOptions()
                restoreOptions.serverMajor = 16
                restoreOptions.dropExisting = format == .custom
                try await DatabaseDump.restore(
                    config,
                    password: "tabula",
                    database: target,
                    options: restoreOptions,
                    from: file
                ) { reports.add($0) }
                var restoredConfig = config
                restoredConfig.database = target
                let restored = try await PostgresDriver.connect(restoredConfig, password: "tabula")
                let rows = try await restored.execute("SELECT id::text, label FROM public.\(table) ORDER BY id").rows
                await restored.close()
                XCTAssertEqual(rows, [["1", "it's"], ["2", "back\\slash"]], format.rawValue)
            }
            // Restoring the archive again without dropping fails on the existing table, and says so.
            let again = temporaryFile("dump")
            defer { try? FileManager.default.removeItem(at: again) }
            var archive = DatabaseDump.DumpOptions()
            archive.format = .custom
            archive.tables = [TableRef(schema: "public", name: table)]
            try await DatabaseDump.dump(config, password: "tabula", database: "tabula", options: archive, to: again) {
                _ in
            }
            var restoreOptions = DatabaseDump.RestoreOptions()
            restoreOptions.serverMajor = 16
            do {
                try await DatabaseDump.restore(
                    config,
                    password: "tabula",
                    database: target,
                    options: restoreOptions,
                    from: again
                ) { _ in }
                XCTFail("The table already exists")
            } catch {
                XCTAssertFalse(error is CancellationError)
                XCTAssertTrue(error.localizedDescription.contains("already exists"), error.localizedDescription)
            }
        }
    }

    func testPostgresFailuresAreReadableAndLeaveNoFile() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"] == "55432" else {
            throw XCTSkip("TABULA_TEST_PG_PORT=55432 not set")
        }
        guard await DatabaseDump.locate(.pgDump) != nil else { throw XCTSkip("pg_dump not installed") }
        let config = ConnectionConfig(
            kind: .postgres,
            host: "127.0.0.1",
            port: 55432,
            user: "tabula",
            database: "tabula"
        )
        let file = temporaryFile("sql")
        do {
            try await DatabaseDump.dump(config, password: "wrong", database: "tabula", options: .init(), to: file) {
                _ in
            }
            XCTFail("A wrong password must fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("password authentication failed"),
                error.localizedDescription
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // A script with a psql command is refused before anything runs.
        let script = temporaryFile("sql")
        try Data("CREATE TABLE never_created_by_tabula (id int);\n\\! touch /tmp/tabula-should-not-exist\n".utf8)
            .write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        do {
            try await DatabaseDump.restore(
                config,
                password: "tabula",
                database: "tabula",
                options: .init(),
                from: script
            ) { _ in }
            XCTFail("psql commands must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("psql command"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/tabula-should-not-exist"))
    }

    func testMySQLDumpAndRestore() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        guard await DatabaseDump.locate(.mysqldump) != nil, await DatabaseDump.locate(.mysql) != nil else {
            throw XCTSkip("mysqldump not installed")
        }
        let config = ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula", tls: .require)
        let driver = try await MySQLDriver.connect(config, password: "tabula")
        let table = "dump_\(UUID().uuidString.prefix(8).lowercased())"
        _ = try await driver.execute("CREATE TABLE \(table) (id INT PRIMARY KEY, label TEXT) ENGINE=InnoDB")
        _ = try await driver.execute("INSERT INTO \(table) VALUES (1, 'it''s'), (2, 'Hà Nội')")
        let file = temporaryFile("sql")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            var options = DatabaseDump.DumpOptions()
            options.tables = [TableRef(schema: "tabula", name: table)]
            options.addDrop = true
            try await DatabaseDump.dump(config, password: "tabula", database: "tabula", options: options, to: file) {
                _ in
            }
            _ = try await driver.execute("DROP TABLE \(table)")
            try await DatabaseDump.restore(config, password: "tabula", database: "tabula", options: .init(), from: file)
            { _ in }
            let rows = try await driver.execute("SELECT id, label FROM \(table) ORDER BY id").rows
            XCTAssertEqual(rows, [["1", "it's"], ["2", "Hà Nội"]])
            // A script can't run commands on this Mac.
            let script = temporaryFile("sql")
            try Data("system touch /tmp/tabula-mysql-should-not-exist\n".utf8).write(to: script)
            defer { try? FileManager.default.removeItem(at: script) }
            try? await DatabaseDump.restore(
                config,
                password: "tabula",
                database: "tabula",
                options: .init(),
                from: script
            ) { _ in }
            XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/tabula-mysql-should-not-exist"))
        } catch {
            _ = try? await driver.execute("DROP TABLE IF EXISTS \(table)")
            await driver.close()
            throw error
        }
        _ = try? await driver.execute("DROP TABLE IF EXISTS \(table)")
        await driver.close()
    }

    /// A failing statement after the first must leave nothing behind, and a tool that stops reading early must not
    /// take the process down (SIGPIPE).
    func testFailedRestoreRollsBackAndSurvivesEarlyExit() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"] == "55432" else {
            throw XCTSkip("TABULA_TEST_PG_PORT=55432 not set")
        }
        guard await DatabaseDump.locate(.psql) != nil else { throw XCTSkip("psql not installed") }
        let config = ConnectionConfig(
            kind: .postgres,
            host: "127.0.0.1",
            port: 55432,
            user: "tabula",
            database: "tabula"
        )
        let table = "rollback_\(UUID().uuidString.prefix(8).lowercased())"
        let script = temporaryFile("sql")
        // Several MB after the failing statement, so psql exits while Tabula is still writing.
        let filler = String(repeating: "SELECT 1;\n", count: 400_000)
        try Data("CREATE TABLE \(table) (id int);\nSELECT * FROM table_that_does_not_exist;\n\(filler)".utf8)
            .write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        var options = DatabaseDump.RestoreOptions()
        options.serverMajor = 16
        do {
            try await DatabaseDump.restore(
                config,
                password: "tabula",
                database: "tabula",
                options: options,
                from: script
            ) { _ in }
            XCTFail("The failing statement must fail the restore")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("table_that_does_not_exist"), error.localizedDescription)
        }
        let driver = try await PostgresDriver.connect(config, password: "tabula")
        let exists = try await driver.execute("SELECT to_regclass('public.\(table)') IS NOT NULL").rows
        await driver.close()
        XCTAssertEqual(exists, [["false"]], "The table created before the failure must be rolled back")
        // A wrong password with the same large script: psql exits at once.
        do {
            try await DatabaseDump.restore(
                config,
                password: "wrong",
                database: "tabula",
                options: options,
                from: script
            ) { _ in }
            XCTFail("A wrong password must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("password"), error.localizedDescription)
        }
    }

    func testCancellingStopsTheTool() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"] == "55432" else {
            throw XCTSkip("TABULA_TEST_PG_PORT=55432 not set")
        }
        guard await DatabaseDump.locate(.psql) != nil else { throw XCTSkip("psql not installed") }
        let config = ConnectionConfig(
            kind: .postgres,
            host: "127.0.0.1",
            port: 55432,
            user: "tabula",
            database: "tabula"
        )
        let script = temporaryFile("sql")
        try Data("SELECT pg_sleep(30);\n".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: script) }
        let started = Date()
        let task = Task {
            try await DatabaseDump.restore(
                config,
                password: "tabula",
                database: "tabula",
                options: .init(),
                from: script
            ) { _ in }
        }
        try await Task.sleep(for: .seconds(1))
        task.cancel()
        // Stopped as soon as it starts, while the tool is still being looked for: cancelled, not "not installed".
        let early = Task {
            try await DatabaseDump.restore(
                config,
                password: "tabula",
                database: "tabula",
                options: .init(),
                from: script
            ) { _ in }
        }
        early.cancel()
        do {
            try await early.value
            XCTFail("Cancelled restore must throw")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        do {
            try await task.value
            XCTFail("Cancelled restore must throw")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var all: [DatabaseDump.Progress] = []
    func add(_ progress: DatabaseDump.Progress) { lock.withLock { all.append(progress) } }
}
