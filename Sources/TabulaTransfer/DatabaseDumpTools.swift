import Darwin
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Finding the client tools: where they are installed, which version each is, and the one a dump or restore needs.
extension DatabaseDump {
    // MARK: Finding the tools

    /// Directories the tools are installed in, besides the login shell's PATH: Postgres.app and Homebrew, including
    /// keg-only formulae (libpq, mysql-client) that aren't linked onto the PATH.
    static func candidateDirectories(for tool: Tool) -> [String] {
        let fm = FileManager.default
        func versions(_ parent: String, prefix: String, suffix: String = "/bin") -> [String] {
            // Install folders that don't exist have no tools; required() reports a tool found nowhere.
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
            // Not on the shell's PATH: the install folders above are searched.
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
        // A tool that can't report its version is skipped in favour of one that can.
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

    static func required(_ tool: Tool, preferMariaDB: Bool? = nil) async throws -> Located {
        guard let located = await locate(tool, preferMariaDB: preferMariaDB) else {
            // Stopped while looking: the tool may well be there.
            try Task.checkCancellation()
            throw DatabaseError("\(tool.rawValue) isn't installed. \(tool.installHint)")
        }
        return located
    }
}
