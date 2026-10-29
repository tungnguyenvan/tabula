import Foundation

extension ConnectionConfig {
    /// A connection read from text copied from another tool or a framework's settings. Accepted:
    /// - URLs, as `parse(url:)` reads them, also behind `jdbc:`: `jdbc:postgresql://host/db?user=app&password=…`;
    /// - `jdbc:sqlite:/path/file.db`;
    /// - libpq key/value strings (PostgreSQL): `host=db port=5432 dbname=app user=app password='a b'`;
    /// - semicolon-separated strings, as .NET and ODBC drivers take them: `Server=db;Port=3306;Database=app;Uid=app;Pwd=…`
    ///   (MySQL), or Npgsql's `Host=db;Username=app;…` (PostgreSQL).
    ///
    /// Nil when the text is none of these.
    public static func parse(connectionString text: String) -> (config: ConnectionConfig, password: String?)? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("jdbc:") { text.removeFirst("jdbc:".count) }
        if text.contains("://") { return parse(url: text) }
        for scheme in ["sqlite:", "sqlite3:"] where text.lowercased().hasPrefix(scheme) {
            let path = String(text.dropFirst(scheme.count))
            guard path.hasPrefix("/") || path.hasPrefix("~") else { return nil }
            return (ConnectionConfig(kind: .sqlite, filePath: (path as NSString).expandingTildeInPath), nil)
        }
        if let pairs = libpqPairs(text) { return keyValueConnection(pairs, libpq: true) }
        if let pairs = semicolonPairs(text) { return keyValueConnection(pairs, libpq: false) }
        return nil
    }

    private static let hostKeys: Set = [
        "host", "hostaddr", "server", "datasource", "address", "addr", "networkaddress",
    ]
    private static let databaseKeys: Set = ["dbname", "database", "initialcatalog"]
    private static let userKeys: Set = ["user", "userid", "uid", "username", "usr"]
    private static let passwordKeys: Set = ["password", "pwd"]

    /// Keys compared without case, spaces or underscores: `User Id`, `SSL Mode` and `ssl_mode` are `userid`, `sslmode`.
    private static func normalized(_ key: String) -> String {
        key.lowercased().filter { !$0.isWhitespace && $0 != "_" }
    }

    private static func keyValueConnection(
        _ pairs: [(key: String, value: String)],
        libpq: Bool
    ) -> (config: ConnectionConfig, password: String?)? {
        var values: [String: String] = [:]
        for pair in pairs { values[normalized(pair.key)] = pair.value }
        let host = values.first { hostKeys.contains($0.key) }?.value
        // A host never holds spaces; one that does is text that only looks like key=value pairs.
        // Without a host, only a libpq string still names a connection (to the local server).
        guard !(host ?? "").contains(where: \.isWhitespace),
            host != nil || (libpq && values.keys.contains { databaseKeys.contains($0) || userKeys.contains($0) })
        else { return nil }

        var port = values["port"].flatMap(Int.init).flatMap { ports.contains($0) ? $0 : nil }
        var hostName = host ?? Defaults.host
        // A port written with the host: db:3306, or db,1433 as ODBC writes it.
        if port == nil, let separator = hostName.lastIndex(where: { $0 == "," || $0 == ":" }),
            hostName.filter({ $0 == ":" }).count <= 1,
            let embedded = Int(hostName[hostName.index(after: separator)...]),
            ports.contains(embedded)
        {
            port = embedded
            hostName = String(hostName[..<separator])
        }

        let kind: DatabaseKind
        if libpq || port == DatabaseKind.postgres.defaultPort {
            kind = .postgres
        } else if port == DatabaseKind.mysql.defaultPort {
            kind = .mysql
        } else {
            // Npgsql's own examples name the server Host; MySQL's name it Server.
            kind = values["host"] != nil && values["server"] == nil ? .postgres : .mysql
        }
        var config = ConnectionConfig(kind: kind, host: hostName.isEmpty ? Defaults.host : hostName, port: port)
        config.database = values.first { databaseKeys.contains($0.key) }?.value ?? ""
        config.user = values.first { userKeys.contains($0.key) }?.value ?? ""
        var options = Options()
        if let mode = values["sslmode"] { apply("sslmode", mode, to: &config, options: &options) }
        return (config, values.first { passwordKeys.contains($0.key) }?.value)
    }

    /// `key=value` pairs separated by spaces, values optionally in single quotes with `\` escapes, as libpq reads them.
    /// Nil unless every word is such a pair with a plain key, and one key names a host, database or user.
    private static func libpqPairs(_ text: String) -> [(key: String, value: String)]? {
        var pairs: [(key: String, value: String)] = []
        var index = text.startIndex
        func skipSpaces() { while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) } }
        while true {
            skipSpaces()
            guard index < text.endIndex else { break }
            let keyStart = index
            while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "_" {
                index = text.index(after: index)
            }
            let key = String(text[keyStart..<index])
            skipSpaces()
            guard !key.isEmpty, index < text.endIndex, text[index] == "=" else { return nil }
            index = text.index(after: index)
            skipSpaces()
            var value = ""
            let quoted = index < text.endIndex && text[index] == "'"
            if quoted { index = text.index(after: index) }
            var closed = !quoted
            while index < text.endIndex {
                let character = text[index]
                if quoted, character == "'" {
                    closed = true
                    index = text.index(after: index)
                    break
                }
                if !quoted, character.isWhitespace { break }
                if character == "\\", text.index(after: index) < text.endIndex {
                    index = text.index(after: index)
                    value.append(text[index])
                } else {
                    value.append(character)
                }
                index = text.index(after: index)
            }
            // An unquoted ";" means another format (Host=db;Username=app), whose first value only looks like this one.
            guard closed, quoted || !value.contains(";") else { return nil }
            pairs.append((key, value))
        }
        let keys = Set(pairs.map { normalized($0.key) })
        guard !keys.isDisjoint(with: hostKeys.union(databaseKeys).union(userKeys)) else { return nil }
        return pairs
    }

    /// `Key=Value;` pairs, values optionally in double or single quotes (a doubled quote stands for one).
    /// Nil without at least two pairs, so a lone `a=b` isn't taken for a connection.
    private static func semicolonPairs(_ text: String) -> [(key: String, value: String)]? {
        var pairs: [(key: String, value: String)] = []
        var key: String?
        var field = ""
        var quoted = false
        var quote: Character?
        func finish() -> Bool {
            defer {
                key = nil
                field = ""
                quoted = false
            }
            guard let name = key?.trimmingCharacters(in: .whitespaces) else {
                return field.trimmingCharacters(in: .whitespaces).isEmpty
            }
            guard !name.isEmpty else { return false }
            pairs.append((name, quoted ? field : field.trimmingCharacters(in: .whitespaces)))
            return true
        }
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if let open = quote {
                guard character == open else {
                    field.append(character)
                    continue
                }
                // A doubled quote is one quote inside the value.
                if index < characters.count, characters[index] == open {
                    field.append(character)
                    index += 1
                } else {
                    quote = nil
                }
            } else if character == ";" {
                guard finish() else { return nil }
            } else if key == nil, character == "=" {
                key = field
                field = ""
            } else if key != nil, !quoted, field.allSatisfy(\.isWhitespace), character == "\"" || character == "'" {
                quote = character
                quoted = true
                field = ""
            } else if !(quoted && quote == nil && character.isWhitespace) {
                field.append(character)
            }
        }
        guard quote == nil, finish() else { return nil }
        return pairs.count >= 2 ? pairs : nil
    }
}
