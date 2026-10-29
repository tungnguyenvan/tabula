import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Tools the chat assistant can use while it answers.
///
/// Every provider calls them the same way: the reply asks for a tool in a ```tool fenced block, Tabula runs it
/// and sends the result back in the next request, until the model answers. Command-line agents (Claude Code,
/// Codex) keep their own tools turned off and need no MCP setup.
public enum AgentTool: String, CaseIterable, Codable, Sendable {
    case listTables = "list_tables"
    case describeTable = "describe_table"
    case runQuery = "run_query"
    case searchSavedQueries = "search_saved_queries"
}

public struct AgentToolCall: Codable, Equatable, Sendable {
    public var tool: AgentTool
    /// list_tables: the schema (database on MySQL and MongoDB) to list; nil lists the current one.
    public var schema: String?
    /// describe_table: `table` or `schema.table`.
    public var table: String?
    /// run_query: one read-only statement.
    public var query: String?
    /// search_saved_queries: words to look for in the user's saved queries.
    public var search: String?

    public init(
        tool: AgentTool,
        schema: String? = nil,
        table: String? = nil,
        query: String? = nil,
        search: String? = nil
    ) {
        self.tool = tool
        self.schema = schema
        self.table = table
        self.query = query
        self.search = search
    }

    /// One line for the conversation: what the assistant looked at.
    public var summary: String {
        switch tool {
        case .listTables: return "Listed tables" + (schema.map { " in \($0)" } ?? "")
        case .describeTable: return "Described \(table ?? "a table")"
        case .runQuery: return "Ran a query"
        case .searchSavedQueries: return "Searched saved queries" + (search.map { " for “\($0)”" } ?? "")
        }
    }

    /// The call as the model wrote it, for the transcript sent back.
    var json: String {
        var object: [String: String] = ["tool": tool.rawValue]
        if let schema {
            object["schema"] = schema
        }
        if let table {
            object["table"] = table
        }
        if let query {
            object["query"] = query
        }
        if let search {
            object["search"] = search
        }
        let data =
            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// How tool calls are written in a reply, and what the model is told about them.
public enum AgentProtocol {
    static let fence = "```tool"

    /// Added to the chat instructions whatever the user's own prompt says, so tools always work.
    public static func instructions(kind: DatabaseKind, canQuery: Bool) -> String {
        let language = kind.isDocument ? "MongoDB shell" : "\(kind.displayName) SQL"
        let read =
            kind.isDocument
            ? "find, findOne, aggregate (without $out or $merge), countDocuments, estimatedDocumentCount, distinct or getIndexes"
            : "SELECT, WITH … SELECT, EXPLAIN (without ANALYZE), SHOW or DESCRIBE"
        var tools = """
            - {"tool": "list_tables", "schema": "<optional schema>"}: the tables and views of a schema (default: the current one).
            - {"tool": "describe_table", "table": "<schema.table>"}: columns with types, indexes and foreign keys.
            - {"tool": "search_saved_queries", "search": "<words>"}: the user's saved queries whose keyword, folder or \
            SQL contain the words. Use it when the user asks for a query they saved, or one they may already have.
            """
        if canQuery {
            tools +=
                "\n- {\"tool\": \"run_query\", \"query\": \"<one \(language) statement>\"}: runs one read-only statement "
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
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // Some models nest the arguments.
        for key in ["arguments", "args", "input", "parameters"] {
            if let nested = object[key] as? [String: Any] { object.merge(nested) { current, _ in current } }
        }
        guard let name = (object["tool"] ?? object["name"]) as? String, let tool = AgentTool(rawValue: name) else {
            return nil
        }
        func text(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        return AgentToolCall(
            tool: tool,
            schema: text("schema"),
            table: text("table"),
            query: text("query") ?? text("sql"),
            search: text("search") ?? text("keyword")
        )
    }

    /// The reply as the user sees it: anything before a tool request.
    public static func visibleText(_ reply: String) -> String {
        guard let open = reply.range(of: fence) else {
            return reply
        }
        return String(reply[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a reply still streaming shows: `visibleText`, without a trailing fence that may be the start of a
    /// tool request ("`", "``", "```", "```to"…). Once the fence turns out to be something else, it shows.
    public static func streamingText(_ reply: String) -> String {
        let text = visibleText(reply)
        guard text.count == reply.count else {
            return text
        }
        if let start = text.range(of: "```", options: .backwards), fence.hasPrefix(text[start.lowerBound...]) {
            return String(text[..<start.lowerBound])
        }
        let ticks = text.reversed().prefix { $0 == "`" }.count
        return ticks > 0 ? String(text.dropLast(ticks)) : text
    }
}

/// Runs the assistant's tool calls against a connection opened for it.
public struct AgentToolbox: Sendable {
    public let driver: any DatabaseDriver
    /// The schema selected in the sidebar, used when a call names none.
    public let currentSchema: String
    /// The user's saved query library (#94), for search_saved_queries.
    public let savedQueries: [SavedQuery]

    public init(driver: any DatabaseDriver, currentSchema: String, savedQueries: [SavedQuery]) {
        self.driver = driver
        self.currentSchema = currentSchema
        self.savedQueries = savedQueries
    }

    /// Makes the agent's own connection read-only where the server can enforce it, and bounds query time.
    public static func prepare(_ driver: any DatabaseDriver) async throws {
        try await driver.catalog.prepareReadOnlySession(timeoutSeconds: Defaults.AI.agentQueryTimeout, on: driver)
    }

    /// The result as text for the model. Errors are returned as text too, so the model can correct itself.
    public func run(_ call: AgentToolCall) async -> String {
        do {
            switch call.tool {
            case .listTables: return try await listTables(call.schema)
            case .describeTable:
                guard let name = call.table else {
                    return "Error: describe_table needs a table."
                }
                return try await describe(name)
            case .runQuery:
                guard let query = call.query else {
                    return "Error: run_query needs a query."
                }
                return try await runQuery(query)
            case .searchSavedQueries:
                guard let search = call.search else {
                    return "Error: search_saved_queries needs words to search for."
                }
                return Self.text(of: SavedQuery.search(savedQueries, for: search), searchedFor: search)
            }
        } catch {
            return "Error: \(SQLPrompts.redacted(error.localizedDescription, kind: driver.kind))"
        }
    }

    private func listTables(_ schema: String?) async throws -> String {
        let schemas = try await driver.schemas()
        let name =
            schema.flatMap { wanted in schemas.first { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
            ?? currentSchema
        if let schema, schemas.first(where: { $0.caseInsensitiveCompare(schema) == .orderedSame }) == nil {
            return "Error: no schema named \(schema). Schemas: \(schemas.joined(separator: ", "))"
        }
        let tables = try await driver.tables(in: name)
        let list = tables.map { $0.kind == .view ? "\($0.name) (view)" : $0.name }
        return "\(name): \(tables.count) \(driver.kind.isDocument ? "collections" : "tables")\n"
            + list.joined(separator: "\n")
            + "\nOther schemas: " + schemas.filter { $0 != name }.joined(separator: ", ")
    }

    private func describe(_ name: String) async throws -> String {
        guard let table = try await resolve(name) else {
            return "Error: no table named \(name). Use list_tables to see them."
        }
        var lines = ["\(table.schema).\(table.name)\(table.kind == .view ? " (view)" : "")", "Columns:"]
        for column in try await driver.columns(of: table) {
            var line = "  \(column.name) \(column.dataType)"
            if column.isPrimaryKey {
                line += " PRIMARY KEY"
            }
            if !column.isNullable {
                line += " NOT NULL"
            }
            if let value = column.defaultValue {
                line += " DEFAULT \(value)"
            }
            if let comment = column.comment, !comment.isEmpty {
                line += " -- \(comment)"
            }
            lines.append(line)
        }
        // Indexes and foreign keys are extra detail for the model; the columns above are what it needs.
        let indexes = (try? await driver.indexes(of: table)) ?? []
        if !indexes.isEmpty {
            lines.append("Indexes:")
            lines += indexes.map {
                "  \($0.name) (\($0.columns.joined(separator: ", ")))\($0.isUnique ? " UNIQUE" : "")"
            }
        }
        let keys = ((try? await driver.foreignKeys(in: table.schema)) ?? [])
            .filter { $0.table == table || $0.referencedTable == table }
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
        if let table = try await find(unquoted, in: currentSchema) {
            return table
        }
        guard let dot = unquoted.firstIndex(of: ".") else { return nil }
        let wanted = String(unquoted[..<dot])
        guard
            let schema = try await driver.schemas().first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame })
        else { return nil }
        return try await find(String(unquoted[unquoted.index(after: dot)...]), in: schema)
    }

    private func runQuery(_ query: String) async throws -> String {
        if let violation = driver.dialect.readOnlyViolation(query) {
            return "Refused: \(violation)"
        }
        let limited = driver.dialect.applyingRowLimit(query, limit: Defaults.AI.agentRowLimit + 1)
        return Self.text(of: try await runReadOnly(limited))
    }

    /// Runs in a read-only transaction of its own on PostgreSQL and MySQL, which a statement can't switch back
    /// to read-write, whatever got past the dialect's `readOnlyViolation`. The connection's session defaults (`prepare`) could be
    /// changed by a statement; a transaction started for each query can't.
    func runReadOnly(_ statement: String) async throws -> QueryResult {
        let timeout = Defaults.AI.agentQueryTimeout
        guard let transaction = driver.catalog.readOnlyTransaction(timeoutSeconds: timeout) else {
            return try await driver.execute(statement)
        }
        let result: QueryResult
        do {
            // Inside the do: once BEGIN has run, any failure must still end the transaction, or the agent's
            // connection stays in an aborted one and every later query fails.
            for opening in transaction {
                _ = try await driver.execute(opening)
            }
            result = try await driver.execute(statement)
        } catch {
            // The original error is the one to report; a failed ROLLBACK ends with the agent's connection anyway.
            _ = try? await driver.execute("ROLLBACK")
            throw error
        }
        // A failed ROLLBACK leaves the connection inside the transaction, so it is reported rather than ignored.
        _ = try await driver.execute("ROLLBACK")
        return result
    }

    /// Saved queries for the model: keyword, folder and SQL, best matches first, cut to the total limit.
    static func text(of matches: [SavedQuery], searchedFor search: String) -> String {
        guard !matches.isEmpty else {
            return "No saved query matches “\(search)”."
        }
        var text = "\(matches.count) saved \(matches.count == 1 ? "query matches" : "queries match") “\(search)”:"
        var shown = 0
        for query in matches {
            let folder = query.group.isEmpty ? "" : " (folder \(query.group))"
            let entry =
                "\n\nKeyword: \(query.keyword)\(folder)\n```sql\n\(query.sql.trimmingCharacters(in: .whitespacesAndNewlines))\n```"
            guard text.count + entry.count < Defaults.AI.agentResultLength else {
                break
            }
            text += entry
            shown += 1
        }
        if shown < matches.count {
            text += "\n\n\(matches.count - shown) more not shown; search with more specific words."
        }
        return text
    }

    /// Rows as tab-separated text, cut to the row, cell and total limits.
    static func text(of result: QueryResult) -> String {
        guard !result.columns.isEmpty else {
            return "No rows returned."
        }
        let rows = result.rows.prefix(Defaults.AI.agentRowLimit)
        func cell(_ value: String?) -> String {
            guard let value else {
                return "NULL"
            }
            let flat = value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            return flat.count > Defaults.AI.agentCellLength
                ? String(flat.prefix(Defaults.AI.agentCellLength)) + "…" : flat
        }
        var text = result.columns.joined(separator: "\t")
        var shown = 0
        for row in rows {
            let line = row.map(cell).joined(separator: "\t")
            guard text.count + line.count < Defaults.AI.agentResultLength else { break }
            text += "\n" + line
            shown += 1
        }
        let noun = shown == 1 ? "row" : "rows"
        let cutOff = result.rows.count > shown ? " shown (more were returned, cut off)" : ""
        return "\(shown) \(noun)\(cutOff):\n" + text
    }

    /// A tool result as the chat shows it: tab-separated rows (`text(of:)`) padded into columns, which a proportional
    /// panel can't do with tabs. Lines without tabs stay as they are.
    public static func aligned(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let cells = lines.map { $0.contains("\t") ? $0.components(separatedBy: "\t") : nil }
        var widths: [Int] = []
        for row in cells.compactMap({ $0 }) {
            for (index, cell) in row.enumerated() {
                if index == widths.count {
                    widths.append(0)
                }
                widths[index] = max(widths[index], cell.count)
            }
        }
        return zip(lines, cells)
            .map { line, row in
                guard let row else {
                    return line
                }
                return row.enumerated()
                    .map { index, cell in
                        index == row.count - 1
                            ? cell : cell.padding(toLength: widths[index] + columnGap, withPad: " ", startingAt: 0)
                    }
                    .joined()
            }
            .joined(separator: "\n")
    }

    private static let columnGap = 2
}
