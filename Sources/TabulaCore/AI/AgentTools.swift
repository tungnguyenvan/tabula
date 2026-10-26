import Foundation

/// Tools the chat assistant can use while it answers.
///
/// Every provider calls them the same way: the reply asks for a tool in a ```tool fenced block, Tabula runs it
/// and sends the result back in the next request, until the model answers. Command-line agents (Claude Code,
/// Codex) keep their own tools turned off and need no MCP setup.
public enum AgentTool: String, CaseIterable, Codable, Sendable {
    case listTables = "list_tables"
    case describeTable = "describe_table"
    case runQuery = "run_query"
}

public struct AgentToolCall: Codable, Equatable, Sendable {
    public var tool: AgentTool
    /// list_tables: the schema (database on MySQL and MongoDB) to list; nil lists the current one.
    public var schema: String?
    /// describe_table: `table` or `schema.table`.
    public var table: String?
    /// run_query: one read-only statement.
    public var query: String?

    public init(tool: AgentTool, schema: String? = nil, table: String? = nil, query: String? = nil) {
        self.tool = tool
        self.schema = schema
        self.table = table
        self.query = query
    }

    /// One line for the conversation: what the assistant looked at.
    public var summary: String {
        switch tool {
        case .listTables: return "Listed tables" + (schema.map { " in \($0)" } ?? "")
        case .describeTable: return "Described \(table ?? "a table")"
        case .runQuery: return "Ran a query"
        }
    }

    /// The call as the model wrote it, for the transcript sent back.
    var json: String {
        var object: [String: String] = ["tool": tool.rawValue]
        if let schema { object["schema"] = schema }
        if let table { object["table"] = table }
        if let query { object["query"] = query }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// How tool calls are written in a reply, and what the model is told about them.
public enum AgentProtocol {
    static let fence = "```tool"

    /// Added to the chat instructions whatever the user's own prompt says, so tools always work.
    public static func instructions(kind: DatabaseKind, canQuery: Bool) -> String {
        let language = kind.isDocument ? "MongoDB shell" : "\(kind.displayName) SQL"
        let read = kind.isDocument
            ? "find, findOne, aggregate (without $out or $merge), countDocuments, estimatedDocumentCount, distinct or getIndexes"
            : "SELECT, WITH … SELECT, EXPLAIN (without ANALYZE), SHOW or DESCRIBE"
        var tools = """
            - {"tool": "list_tables", "schema": "<optional schema>"}: the tables and views of a schema (default: the current one).
            - {"tool": "describe_table", "table": "<schema.table>"}: columns with types, indexes and foreign keys.
            """
        if canQuery {
            tools += "\n- {\"tool\": \"run_query\", \"query\": \"<one \(language) statement>\"}: runs one read-only statement "
                + "(\(read)) and returns at most \(Defaults.AI.agentRowLimit) rows. Anything that changes data is refused."
        }
        return """
            You can look things up in the database with tools. To use one, reply with only a fenced block and stop:
            ```tool
            {"tool": "describe_table", "table": "public.orders"}
            ```
            Tabula runs it and sends you the result. Use one tool per reply and only when the schema above isn't enough\
            \(canQuery ? " or the question is about the data" : ""). Tools:
            \(tools)
            Never use a tool to change data: write such statements in a ```sql block for the user to run.\
            \(canQuery ? "" : " You can't see rows, only the structure; say so if a question needs the data.")
            """
    }

    /// The first tool call in a reply; nil when the reply is an answer.
    public static func call(in reply: String) -> AgentToolCall? {
        guard let open = reply.range(of: fence) else { return nil }
        var body = reply[open.upperBound...]
        if let close = body.range(of: "```") { body = body[..<close.lowerBound] }
        guard let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Some models nest the arguments.
        for key in ["arguments", "args", "input", "parameters"] {
            if let nested = object[key] as? [String: Any] { object.merge(nested) { current, _ in current } }
        }
        guard let name = (object["tool"] ?? object["name"]) as? String, let tool = AgentTool(rawValue: name) else { return nil }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        return AgentToolCall(tool: tool, schema: text("schema"), table: text("table"), query: text("query") ?? text("sql"))
    }

    /// The reply as the user sees it: anything before a tool request.
    public static func visibleText(_ reply: String) -> String {
        guard let open = reply.range(of: fence) else { return reply }
        return String(reply[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a reply still streaming shows: `visibleText`, without a trailing fence that may be the start of a
    /// tool request ("`", "``", "```", "```to"…). Once the fence turns out to be something else, it shows.
    public static func streamingText(_ reply: String) -> String {
        let text = visibleText(reply)
        guard text.count == reply.count else { return text }
        if let start = text.range(of: "```", options: .backwards), fence.hasPrefix(text[start.lowerBound...]) {
            return String(text[..<start.lowerBound])
        }
        let ticks = text.reversed().prefix { $0 == "`" }.count
        return ticks > 0 ? String(text.dropLast(ticks)) : text
    }
}

/// Decides whether a statement the assistant wants to run only reads. This is the first check; the agent's
/// own connection is also read-only where the server supports it (see `AgentToolbox.prepare`).
public enum AgentReadOnly {
    /// Why the statement can't run, or nil when it only reads.
    public static func violation(_ statement: String, kind: DatabaseKind) -> String? {
        kind.isDocument ? mongoViolation(statement) : sqlViolation(statement, kind: kind)
    }

    private static let firstWords: Set<String> = ["SELECT", "WITH", "EXPLAIN", "SHOW", "DESCRIBE", "DESC", "VALUES", "TABLE"]
    private static let writingWords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "CREATE", "DROP", "ALTER", "TRUNCATE", "RENAME",
        "GRANT", "REVOKE", "COPY", "CALL", "DO", "LOCK", "UNLOCK", "VACUUM", "ANALYZE", "REINDEX", "CLUSTER", "ATTACH",
        "DETACH", "SET", "RESET", "PRAGMA", "LOAD", "HANDLER", "PREPARE", "EXECUTE", "DEALLOCATE",
        "LISTEN", "NOTIFY", "REFRESH", "IMPORT", "OUTFILE", "DUMPFILE", "KILL", "SHUTDOWN", "BEGIN", "COMMIT", "ROLLBACK",
        "SAVEPOINT", "RELEASE", "START",
    ]
    /// Functions that act on the server or read its files, even in a read-only transaction.
    private static let blockedFunctions: Set<String> = [
        "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE", "SET_CONFIG", "PG_SLEEP",
        "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_LS_DIR", "PG_STAT_FILE", "LO_IMPORT", "LO_EXPORT", "LO_UNLINK",
        "DBLINK", "DBLINK_EXEC", "PG_ADVISORY_LOCK", "PG_TRY_ADVISORY_LOCK", "SLEEP", "BENCHMARK", "LOAD_FILE",
        "GET_LOCK", "RELEASE_LOCK", "LOAD_EXTENSION", "READFILE", "WRITEFILE",
    ]

    private static func sqlViolation(_ statement: String, kind: DatabaseKind) -> String? {
        let statements = SQLSplitter.split(statement, kind: kind)
        guard statements.count == 1 else { return "Run one statement at a time." }
        let words = SQLLexer.tokens(statement, kind: kind).filter { $0.kind == .word }
        guard let first = words.first?.keyword, firstWords.contains(first) else {
            return "Only SELECT, WITH, EXPLAIN, SHOW and DESCRIBE statements can run; this one may change data."
        }
        if let word = words.first(where: { writingWords.contains($0.keyword) }) {
            return "\(word.keyword) can change data or the session, so the statement can't run."
        }
        // SELECT … INTO makes a table or a file and FOR UPDATE / FOR SHARE locks rows; inside parentheses the
        // words mean something else (`substring(x FROM 1 FOR 3)`).
        var depth = 0
        for token in SQLLexer.tokens(statement, kind: kind) {
            if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
            if depth == 0, token.keyword == "INTO" || token.keyword == "FOR" {
                return "\(token.keyword) at the top level writes or locks rows, so the statement can't run."
            }
        }
        if let call = words.first(where: { blockedFunctions.contains($0.keyword) }) {
            return "\(call.text) acts on the server, so the statement can't run."
        }
        return nil
    }

    private static let readMethods: Set<String> = ["find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount",
                                                   "distinct", "getIndexes", "count"]
    private static let databaseReadMethods: Set<String> = ["getCollectionNames", "getCollectionInfos", "stats", "version", "getName"]

    private static func mongoViolation(_ text: String) -> String? {
        let statements = MongoSplitter.statements(in: text)
        guard statements.count == 1 else { return "Run one command at a time." }
        guard let statement = try? MongoStatement.parse(text) else { return "The command couldn't be read." }
        switch statement.target {
        case .show(let what):
            return ["dbs", "databases", "collections", "tables"].contains(what) ? nil : "Only show dbs and show collections can run."
        case .use:
            return "use changes the database; name the collection instead."
        case .database:
            guard let method = statement.method, databaseReadMethods.contains(method) else {
                return "Only collection reads (find, aggregate, countDocuments, distinct) can run."
            }
            return nil
        case .collection:
            guard let method = statement.method, readMethods.contains(method) else {
                return "Only find, findOne, aggregate, countDocuments, estimatedDocumentCount, distinct and getIndexes can run."
            }
            if method == "aggregate", text.contains("$out") || text.contains("$merge") {
                return "$out and $merge write to a collection, so the pipeline can't run."
            }
            return nil
        }
    }
}

/// Runs the assistant's tool calls against a connection opened for it.
public struct AgentToolbox: Sendable {
    public let driver: any DatabaseDriver
    /// The schema selected in the sidebar, used when a call names none.
    public let currentSchema: String

    public init(driver: any DatabaseDriver, currentSchema: String) {
        self.driver = driver
        self.currentSchema = currentSchema
    }

    /// Makes the agent's own connection read-only where the server can enforce it, and bounds query time.
    public static func prepare(_ driver: any DatabaseDriver) async throws {
        switch driver.kind {
        case .postgres:
            _ = try await driver.execute("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
            _ = try await driver.execute("SET statement_timeout = \(Defaults.AI.agentQueryTimeout * 1000)")
        case .mysql:
            _ = try await driver.execute("SET SESSION TRANSACTION READ ONLY")
            _ = try? await driver.execute("SET SESSION max_execution_time = \(Defaults.AI.agentQueryTimeout * 1000)")
        case .sqlite:
            _ = try await driver.execute("PRAGMA query_only = ON")
        case .mongodb, .redis:
            break
        }
    }

    /// The result as text for the model. Errors are returned as text too, so the model can correct itself.
    public func run(_ call: AgentToolCall) async -> String {
        do {
            switch call.tool {
            case .listTables: return try await listTables(call.schema)
            case .describeTable:
                guard let name = call.table else { return "Error: describe_table needs a table." }
                return try await describe(name)
            case .runQuery:
                guard let query = call.query else { return "Error: run_query needs a query." }
                return try await runQuery(query)
            }
        } catch {
            return "Error: \(SQLPrompts.redacted(error.localizedDescription, kind: driver.kind))"
        }
    }

    private func listTables(_ schema: String?) async throws -> String {
        let schemas = try await driver.schemas()
        let name = schema.flatMap { wanted in schemas.first { $0.caseInsensitiveCompare(wanted) == .orderedSame } } ?? currentSchema
        if let schema, schemas.first(where: { $0.caseInsensitiveCompare(schema) == .orderedSame }) == nil {
            return "Error: no schema named \(schema). Schemas: \(schemas.joined(separator: ", "))"
        }
        let tables = try await driver.tables(in: name)
        let list = tables.map { $0.kind == .view ? "\($0.name) (view)" : $0.name }
        return "\(name): \(tables.count) \(driver.kind.isDocument ? "collections" : "tables")\n" + list.joined(separator: "\n")
            + "\nOther schemas: " + schemas.filter { $0 != name }.joined(separator: ", ")
    }

    private func describe(_ name: String) async throws -> String {
        guard let table = try await resolve(name) else { return "Error: no table named \(name). Use list_tables to see them." }
        var lines = ["\(table.schema).\(table.name)\(table.kind == .view ? " (view)" : "")", "Columns:"]
        for column in try await driver.columns(of: table) {
            var line = "  \(column.name) \(column.dataType)"
            if column.isPrimaryKey { line += " PRIMARY KEY" }
            if !column.isNullable { line += " NOT NULL" }
            if let value = column.defaultValue { line += " DEFAULT \(value)" }
            if let comment = column.comment, !comment.isEmpty { line += " -- \(comment)" }
            lines.append(line)
        }
        let indexes = (try? await driver.indexes(of: table)) ?? []
        if !indexes.isEmpty {
            lines.append("Indexes:")
            lines += indexes.map { "  \($0.name) (\($0.columns.joined(separator: ", ")))\($0.isUnique ? " UNIQUE" : "")" }
        }
        let keys = ((try? await driver.foreignKeys(in: table.schema)) ?? []).filter { $0.table == table || $0.referencedTable == table }
        if !keys.isEmpty {
            lines.append("Foreign keys:")
            lines += keys.map { key in
                "  \(key.table.name)(\(key.columns.joined(separator: ", "))) -> \(key.referencedTable.schema).\(key.referencedTable.name)"
                    + "(\(key.referencedColumns.joined(separator: ", ")))"
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `table` in the current schema, else `schema.table`. Names may be quoted; collection names may hold dots.
    private func resolve(_ name: String) async throws -> TableRef? {
        let unquoted = name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "`", with: "")
        func find(_ table: String, in schema: String) async throws -> TableRef? {
            try await driver.tables(in: schema).first { $0.name.caseInsensitiveCompare(table) == .orderedSame }
        }
        if let table = try await find(unquoted, in: currentSchema) { return table }
        guard let dot = unquoted.firstIndex(of: ".") else { return nil }
        let wanted = String(unquoted[..<dot])
        guard let schema = try await driver.schemas().first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) else { return nil }
        return try await find(String(unquoted[unquoted.index(after: dot)...]), in: schema)
    }

    private func runQuery(_ query: String) async throws -> String {
        if let violation = AgentReadOnly.violation(query, kind: driver.kind) { return "Refused: \(violation)" }
        let limited = driver.dialect.applyingRowLimit(query, limit: Defaults.AI.agentRowLimit + 1)
        let result = try await driver.execute(limited)
        return Self.text(of: result)
    }

    /// Rows as tab-separated text, cut to the row, cell and total limits.
    static func text(of result: QueryResult) -> String {
        guard !result.columns.isEmpty else { return "No rows returned." }
        let rows = result.rows.prefix(Defaults.AI.agentRowLimit)
        func cell(_ value: String?) -> String {
            guard let value else { return "NULL" }
            let flat = value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            return flat.count > Defaults.AI.agentCellLength ? String(flat.prefix(Defaults.AI.agentCellLength)) + "…" : flat
        }
        var text = result.columns.joined(separator: "\t")
        var shown = 0
        for row in rows {
            let line = row.map(cell).joined(separator: "\t")
            guard text.count + line.count < Defaults.AI.agentResultLength else { break }
            text += "\n" + line
            shown += 1
        }
        let more = result.rows.count > shown
        return "\(shown) row\(shown == 1 ? "" : "s")\(more ? " shown (more were returned, cut off)" : ""):\n" + text
    }
}
