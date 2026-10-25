import Foundation

/// A function, procedure or trigger stored in the database.
public struct RoutineInfo: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case function, procedure, trigger

        public var displayName: String {
            switch self {
            case .function: "Function"
            case .procedure: "Procedure"
            case .trigger: "Trigger"
            }
        }
    }

    public var kind: Kind
    public var schema: String
    public var name: String
    /// Postgres: the identity arguments that tell overloads apart; empty elsewhere.
    public var arguments: String
    /// Triggers: the table they fire on.
    public var table: String?
    /// One line for the sidebar, e.g. "returns integer" or "BEFORE INSERT ON orders".
    public var detail: String
    /// Postgres object id, used to read the definition.
    public var oid: String?

    public var id: String { "\(kind.rawValue):\(schema).\(table.map { "\($0)." } ?? "")\(name)(\(arguments))" }
    public var displayName: String { kind == .trigger || arguments.isEmpty ? name : "\(name)(\(arguments))" }

    public init(kind: Kind, schema: String, name: String, arguments: String = "", table: String? = nil, detail: String = "", oid: String? = nil) {
        self.kind = kind
        self.schema = schema
        self.name = name
        self.arguments = arguments
        self.table = table
        self.detail = detail
        self.oid = oid
    }
}

extension DatabaseDriver {
    /// Functions, procedures and triggers in `schema`. Postgres functions that belong to an extension are
    /// left out (they aren't the user's to edit).
    public func routines(in schema: String) async throws -> [RoutineInfo] {
        let d = dialect
        switch kind {
        case .postgres:
            let functions = try await execute("""
                SELECT p.oid::text AS oid, p.proname AS name, p.prokind AS kind,
                       pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS result
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = \(d.literal(schema)) AND p.prokind IN ('f', 'p')
                  AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = p.oid AND e.deptype = 'e')
                ORDER BY p.proname, args
                """).records.map { row in
                RoutineInfo(kind: row["kind"] == "p" ? .procedure : .function, schema: schema, name: row["name"] ?? "",
                            arguments: row["args"] ?? "", detail: row["result"].map { "returns \($0)" } ?? "", oid: row["oid"])
            }
            let triggers = try await execute("""
                SELECT t.oid::text AS oid, t.tgname AS name, c.relname AS table_name,
                       CASE WHEN t.tgtype & 2 = 2 THEN 'BEFORE' WHEN t.tgtype & 64 = 64 THEN 'INSTEAD OF' ELSE 'AFTER' END AS timing,
                       concat_ws(' OR ', CASE WHEN t.tgtype & 4 = 4 THEN 'INSERT' END, CASE WHEN t.tgtype & 16 = 16 THEN 'UPDATE' END,
                                 CASE WHEN t.tgtype & 8 = 8 THEN 'DELETE' END, CASE WHEN t.tgtype & 32 = 32 THEN 'TRUNCATE' END) AS events
                FROM pg_trigger t
                JOIN pg_class c ON c.oid = t.tgrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(d.literal(schema)) AND NOT t.tgisinternal
                ORDER BY c.relname, t.tgname
                """).records.map { row in
                RoutineInfo(kind: .trigger, schema: schema, name: row["name"] ?? "", table: row["table_name"],
                            detail: "\(row["timing"] ?? "") \(row["events"] ?? "") ON \(row["table_name"] ?? "")", oid: row["oid"])
            }
            return functions + triggers
        case .mysql:
            let routines = try await execute("""
                SELECT ROUTINE_NAME, ROUTINE_TYPE, DTD_IDENTIFIER FROM information_schema.ROUTINES
                WHERE ROUTINE_SCHEMA = \(d.literal(schema)) ORDER BY ROUTINE_NAME
                """).records.map { row in
                RoutineInfo(kind: row["ROUTINE_TYPE"] == "PROCEDURE" ? .procedure : .function, schema: schema,
                            name: row["ROUTINE_NAME"] ?? "", detail: row["DTD_IDENTIFIER"].map { "returns \($0)" } ?? "")
            }
            let triggers = try await execute("""
                SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION FROM information_schema.TRIGGERS
                WHERE TRIGGER_SCHEMA = \(d.literal(schema)) ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME
                """).records.map { row in
                RoutineInfo(kind: .trigger, schema: schema, name: row["TRIGGER_NAME"] ?? "", table: row["EVENT_OBJECT_TABLE"],
                            detail: "\(row["ACTION_TIMING"] ?? "") \(row["EVENT_MANIPULATION"] ?? "") ON \(row["EVENT_OBJECT_TABLE"] ?? "")")
            }
            return routines + triggers
        case .sqlite:
            let master = schema == "temp" ? "sqlite_temp_master" : "\(d.quoteIdentifier(schema)).sqlite_master"
            return try await execute("SELECT name, tbl_name FROM \(master) WHERE type = 'trigger' ORDER BY tbl_name, name").records.map { row in
                RoutineInfo(kind: .trigger, schema: schema, name: row["name"] ?? "", table: row["tbl_name"],
                            detail: "ON \(row["tbl_name"] ?? "")")
            }
        case .redis, .mongodb:
            return []
        }
    }

    /// The statement that creates the routine as it is now.
    public func definition(of routine: RoutineInfo) async throws -> String {
        let d = dialect
        let text: String?
        switch (kind, routine.kind) {
        case (.postgres, .trigger):
            guard let oid = routine.oid else { throw DatabaseError("Unknown trigger.") }
            text = try await execute("SELECT pg_get_triggerdef(\(d.literal(oid))::oid, true) AS sql").records.first?["sql"].map { $0 + ";" }
        case (.postgres, _):
            guard let oid = routine.oid else { throw DatabaseError("Unknown function.") }
            text = try await execute("SELECT pg_get_functiondef(\(d.literal(oid))::oid) AS sql").records.first?["sql"]
        case (.mysql, _):
            let keyword = routine.kind == .trigger ? "TRIGGER" : routine.kind == .procedure ? "PROCEDURE" : "FUNCTION"
            let row = try await execute("SHOW CREATE \(keyword) \(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.name))").records.first
            text = routine.kind == .trigger ? row?["SQL Original Statement"] : row?["Create \(keyword.capitalized)"]
        case (.sqlite, _):
            let master = routine.schema == "temp" ? "sqlite_temp_master" : "\(d.quoteIdentifier(routine.schema)).sqlite_master"
            text = try await execute("SELECT sql FROM \(master) WHERE type = 'trigger' AND name = \(d.literal(routine.name))").records.first?["sql"]
                .map { $0 + ";" }
        case (.redis, _), (.mongodb, _):
            text = nil
        }
        guard let text, !text.isEmpty else {
            throw DatabaseError("The server didn't return the definition of \(routine.name). The account may lack the privilege to see it.")
        }
        return text
    }

    /// Statement that removes the routine.
    public func dropStatement(for routine: RoutineInfo) -> String {
        let d = dialect
        let qualified = kind == .sqlite && routine.schema == "main"
            ? d.quoteIdentifier(routine.name) : "\(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.name))"
        switch (kind, routine.kind) {
        case (.postgres, .trigger):
            return "DROP TRIGGER \(d.quoteIdentifier(routine.name)) ON \(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.table ?? ""))"
        case (.postgres, .procedure): return "DROP PROCEDURE \(qualified)(\(routine.arguments))"
        case (.postgres, _): return "DROP FUNCTION \(qualified)(\(routine.arguments))"
        case (_, .trigger): return "DROP TRIGGER \(qualified)"
        case (_, .procedure): return "DROP PROCEDURE \(qualified)"
        case (_, .function): return "DROP FUNCTION \(qualified)"
        }
    }

    /// Replaces the routine with `newDefinition` (a full CREATE statement).
    ///
    /// - Postgres functions: `CREATE OR REPLACE` replaces in place.
    /// - Postgres and SQLite triggers: dropped and recreated in one transaction, so a mistake changes nothing.
    /// - MySQL has no transactional DDL: the routine is dropped and recreated, and if the new definition
    ///   fails, the original is put back before the error is reported.
    public func replace(_ routine: RoutineInfo, original: String, with newDefinition: String) async throws {
        switch (kind, routine.kind) {
        case (.postgres, .function), (.postgres, .procedure):
            _ = try await execute(newDefinition)
        case (.postgres, .trigger), (.sqlite, _):
            try await applyInTransaction([dropStatement(for: routine), newDefinition])
        case (.mysql, _):
            _ = try await execute(dropStatement(for: routine))
            do {
                _ = try await execute(newDefinition)
            } catch {
                do {
                    _ = try await execute(original)
                } catch let restoreError {
                    throw DatabaseError("\(error.localizedDescription)\nRestoring the original also failed: \(restoreError.localizedDescription). "
                        + "Its definition is still in the editor.")
                }
                throw DatabaseError("\(error.localizedDescription)\nThe original \(routine.kind.displayName.lowercased()) was restored.")
            }
        case (.redis, _), (.mongodb, _):
            throw DatabaseError("\(kind.displayName) has no routines here.")
        }
    }

    /// A starting point for a new routine.
    public func template(for kind: RoutineInfo.Kind, schema: String, table: String?) -> String {
        let d = dialect
        let target = table.map(d.quoteIdentifier) ?? "table_name"
        switch (self.kind, kind) {
        case (.postgres, .trigger):
            return """
                CREATE TRIGGER new_trigger
                BEFORE UPDATE ON \(d.quoteIdentifier(schema)).\(target)
                FOR EACH ROW EXECUTE FUNCTION \(d.quoteIdentifier(schema)).trigger_function();
                """
        case (.postgres, .procedure):
            return """
                CREATE OR REPLACE PROCEDURE \(d.quoteIdentifier(schema)).new_procedure()
                LANGUAGE plpgsql
                AS $$
                BEGIN
                END;
                $$;
                """
        case (.postgres, .function):
            return """
                CREATE OR REPLACE FUNCTION \(d.quoteIdentifier(schema)).new_function()
                RETURNS integer
                LANGUAGE sql
                AS $$
                    SELECT 1;
                $$;
                """
        case (.mysql, .trigger):
            return "CREATE TRIGGER new_trigger BEFORE UPDATE ON \(target)\nFOR EACH ROW\nBEGIN\n    SET NEW.updated_at = NOW();\nEND"
        case (.mysql, .procedure):
            return "CREATE PROCEDURE new_procedure()\nBEGIN\n    SELECT 1;\nEND"
        case (.mysql, .function):
            return "CREATE FUNCTION new_function() RETURNS INT DETERMINISTIC\nBEGIN\n    RETURN 1;\nEND"
        case (_, _):
            return "CREATE TRIGGER new_trigger AFTER UPDATE ON \(target)\nBEGIN\n    SELECT 1;\nEND;"
        }
    }

    /// Whether this database stores functions (SQLite has triggers only).
    public var supportsFunctions: Bool { kind == .postgres || kind == .mysql }
}
