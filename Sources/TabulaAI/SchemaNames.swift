import Foundation
import Observation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// What a workspace knows about its schema's names, for completion and for the AI: each table's columns, loaded
/// when first needed, other schemas' table names, and the selected schema's foreign keys. When the table list or
/// the database changes, what was known is dropped, and loads still running for the old names throw their
/// results away.
///
/// Loading is best effort: a table whose columns can't be read (no privilege, dropped meanwhile) offers none,
/// and completion and the AI go on with the rest; the sidebar reports connection problems.
@MainActor @Observable
public final class SchemaNames {
    /// Where the names come from: the workspace's connection and what its sidebar shows.
    public struct Source {
        let driver: (any DatabaseDriver)?
        let kind: DatabaseKind
        let tables: [TableRef]
        let schemas: [String]
        let selectedSchema: String

        public init(
            driver: (any DatabaseDriver)?,
            kind: DatabaseKind,
            tables: [TableRef],
            schemas: [String],
            selectedSchema: String
        ) {
            self.driver = driver
            self.kind = kind
            self.tables = tables
            self.schemas = schemas
            self.selectedSchema = selectedSchema
        }
    }

    public init() {}

    /// "schema.table" (lower-cased) → columns.
    private var columns: [String: [ColumnInfo]] = [:]
    private var loadingColumns: Set<String> = []
    private var prefetching = false
    /// The selected schema's foreign keys, loaded for the AI the first time it is asked.
    private var foreignKeys: [ForeignKeyInfo]?
    /// Bumped when the table list changes; loads started before then are dropped.
    private var tablesGeneration = 0
    /// Other schemas' table names, lower-cased schema → names.
    private var schemaTables: [String: [String]] = [:]
    private var loadingSchemaTables: Set<String> = []
    /// Bumped when the window moves to another database; schema table loads started before then are dropped.
    private var databaseGeneration = 0
    /// Bumped when completion learns names, so the editor can refresh its suggestion.
    public private(set) var version = 0

    /// The table list was reloaded (refresh, schema switch, DDL): columns and foreign keys are read again.
    public func tablesChanged() {
        columns = [:]
        foreignKeys = nil
        loadingColumns = []
        tablesGeneration += 1
    }

    /// The window moved to another database: other schemas' tables are read again too.
    public func databaseChanged() {
        schemaTables = [:]
        loadingSchemaTables = []
        databaseGeneration += 1
    }

    private static func key(_ table: TableRef) -> String {
        "\(table.schema.lowercased()).\(table.name.lowercased())"
    }

    /// Loads the columns of the schema's tables in the background, so completion knows them before the
    /// statement names a table.
    public func prefetchColumns(from source: Source) {
        guard let driver = source.driver, !prefetching else { return }
        let pending = source.tables.prefix(Defaults.completionPrefetchLimit).filter { columns[Self.key($0)] == nil }
        guard !pending.isEmpty else { return }
        prefetching = true
        let generation = tablesGeneration
        Task {
            defer {
                prefetching = false
            }
            for table in pending {
                let key = Self.key(table)
                guard generation == tablesGeneration else {
                    return
                }
                guard columns[key] == nil, !loadingColumns.contains(key) else {
                    continue
                }
                loadingColumns.insert(key)
                let loaded = (try? await driver.columns(of: table)) ?? []
                guard generation == tablesGeneration else {
                    return
                }
                loadingColumns.remove(key)
                columns[key] = loaded
                version += 1
            }
        }
    }

    /// Table names of another schema, for completing `schema.`; nil while they load.
    public func tableNames(inSchema schema: String, from source: Source) -> [String]? {
        if schema.caseInsensitiveCompare(source.selectedSchema) == .orderedSame {
            return source.tables.map(\.name)
        }
        let key = schema.lowercased()
        if let cached = schemaTables[key] {
            return cached
        }
        guard let driver = source.driver, !loadingSchemaTables.contains(key),
            let name = source.schemas.first(where: { $0.caseInsensitiveCompare(schema) == .orderedSame })
        else {
            return nil
        }
        loadingSchemaTables.insert(key)
        let generation = databaseGeneration
        Task {
            let names = (try? await driver.tables(in: name).map(\.name)) ?? []
            guard generation == databaseGeneration else {
                return
            }
            schemaTables[key] = names
            loadingSchemaTables.remove(key)
            version += 1
        }
        return nil
    }

    /// A table's column names if already loaded; otherwise starts loading them and returns nil,
    /// so completion offers them from the next keystroke on.
    public func columnNames(of table: SQLCompletion.TableName, from source: Source) -> [String]? {
        let ref: TableRef
        if let schemaName = table.schema, schemaName.caseInsensitiveCompare(source.selectedSchema) != .orderedSame {
            // Another schema: only one the database has. A mistyped one gets no columns rather than a
            // same-named table's from the selected schema.
            guard
                let schema = source.schemas.first(where: { $0.caseInsensitiveCompare(schemaName) == .orderedSame })
            else {
                return nil
            }
            ref = TableRef(schema: schema, name: table.name)
        } else if let known = source.tables.first(where: {
            $0.name.caseInsensitiveCompare(table.name) == .orderedSame
        }) {
            ref = known
        } else {
            return nil
        }
        let key = Self.key(ref)
        if let cached = columns[key] {
            return cached.map(\.name)
        }
        guard let driver = source.driver, !loadingColumns.contains(key) else {
            return nil
        }
        loadingColumns.insert(key)
        let generation = tablesGeneration
        Task {
            let loaded = (try? await driver.columns(of: ref)) ?? []
            guard generation == tablesGeneration else {
                return
            }
            loadingColumns.remove(key)
            columns[key] = loaded
            version += 1
        }
        return nil
    }

    /// Every column name of the selected schema loaded so far, for completion before a table is named.
    public func knownColumnNames(inSchema schema: String) -> [String] {
        let prefix = schema.lowercased() + "."
        let names = columns.filter { $0.key.hasPrefix(prefix) }.values.joined().map(\.name)
        return Array(Set(names)).sorted()
    }

    /// The schema for Ask AI and Fix with AI: waits for columns still loading (up to the prefetch limit)
    /// and for foreign keys, and adds tables of other schemas that `sql` names.
    public func loadedAISchema(for sql: String, from source: Source) async -> SQLPrompts.Schema {
        guard let driver = source.driver else {
            return aiSchema(from: source)
        }
        let generation = tablesGeneration
        // Tables the text names come first and are always loaded; the others only while time allows.
        var named: [TableRef] = []
        var extra: [TableRef] = []
        for reference in driver.dialect.referencedTables(in: sql) {
            if let schemaName = reference.schema,
                schemaName.caseInsensitiveCompare(source.selectedSchema) != .orderedSame
            {
                guard
                    let schema = source.schemas.first(where: {
                        $0.caseInsensitiveCompare(schemaName) == .orderedSame
                    })
                else {
                    continue
                }
                let table = TableRef(schema: schema, name: reference.name)
                named.append(table)
                extra.append(table)
            } else if let table = source.tables.first(where: {
                $0.name.caseInsensitiveCompare(reference.name) == .orderedSame
            }) {
                named.append(table)
            }
        }
        let others = source.tables.prefix(Defaults.completionPrefetchLimit).filter { table in !named.contains(table) }
        let deadline = ContinuousClock.now + .seconds(Defaults.AI.schemaWait)
        for (index, table) in (named + others).enumerated() where columns[Self.key(table)] == nil {
            // Stop (the user cancelled) or run out of time: send what is known.
            if Task.isCancelled || (index >= named.count && ContinuousClock.now >= deadline) {
                break
            }
            let loaded = (try? await driver.columns(of: table)) ?? []
            guard generation == tablesGeneration else {
                return aiSchema(from: source)
            }
            columns[Self.key(table)] = loaded
        }
        if foreignKeys == nil, !Task.isCancelled, ContinuousClock.now < deadline {
            let keys = (try? await driver.foreignKeys(in: source.selectedSchema)) ?? []
            if generation == tablesGeneration {
                foreignKeys = keys
            }
        }
        return aiSchema(extra: extra, from: source)
    }

    /// The schema as the AI sees it: names written as SQL needs them (schema-qualified), column types,
    /// primary and foreign keys. Never rows. With `focus`, only those tables get their columns, which keeps
    /// requests made while typing small.
    public func aiSchema(focus: Set<String>? = nil, extra: [TableRef] = [], from source: Source) -> SQLPrompts.Schema {
        func described(_ table: TableRef) -> SQLPrompts.Schema.Table {
            let name = Self.aiName(table, kind: source.kind, selectedSchema: source.selectedSchema)
            var inFocus = true
            if let focus {
                inFocus = focus.contains(table.name.lowercased()) || focus.contains(name.lowercased())
            }
            var described: [SQLPrompts.Schema.Column] = []
            if inFocus {
                described = (columns[Self.key(table)] ?? [])
                    .map { column in
                        SQLPrompts.Schema.Column(
                            name: column.name,
                            type: column.dataType,
                            isPrimaryKey: column.isPrimaryKey
                        )
                    }
            }
            return SQLPrompts.Schema.Table(name: name, columns: described)
        }
        let keys = (foreignKeys ?? [])
            .compactMap { key -> String? in
                guard let target = key.referencedColumns.first, let column = key.columns.first else {
                    return nil
                }
                let from = Self.aiName(key.table, kind: source.kind, selectedSchema: source.selectedSchema)
                let to = Self.aiName(key.referencedTable, kind: source.kind, selectedSchema: source.selectedSchema)
                return "\(from).\(column) -> \(to).\(target)"
            }
        let defaultSchema = source.kind == .sqlite ? nil : source.selectedSchema
        var schema = SQLPrompts.Schema(
            tables: (source.tables + extra).map(described),
            foreignKeys: focus == nil ? keys : [],
            defaultSchema: defaultSchema
        )
        schema.isDocument = source.kind.isDocument
        return schema
    }

    /// `schema.table`, quoting names that need it; SQLite's main database needs no prefix.
    private static func aiName(_ table: TableRef, kind: DatabaseKind, selectedSchema: String) -> String {
        guard let flavor = SQLFlavor(kind) else {
            // MongoDB: collections are named as the shell reaches them from the current database.
            return table.schema == selectedSchema ? table.name : "\(table.schema).\(table.name)"
        }
        let dialect = SQLDialect(flavor: flavor)
        func part(_ name: String) -> String {
            let isPlain = name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil
            return isPlain ? name : dialect.quoteIdentifier(name)
        }
        if flavor == .sqlite && table.schema == "main" {
            return part(table.name)
        }
        return "\(part(table.schema)).\(part(table.name))"
    }
}
