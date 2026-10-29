import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// PostgreSQL's result edits: typed E'…' literals and `IS NOT DISTINCT FROM` for the old values, returning the row
/// as it is after the update.
struct PostgresResultEditWriter: ResultEditWriter {
    var kind: DatabaseKind { .postgres }

    /// Types whose text form round-trips without a time zone, locale or binary codec, with the cast that reads them.
    static let castTypes: [UInt32: String] = [
        16: "bool", 20: "int8", 21: "int2", 23: "int4", 25: "text", 1042: "bpchar",
        1043: "varchar", 1700: "numeric", 2950: "uuid",
    ]
    static var scalarTypes: Set<UInt32> { Set(castTypes.keys) }

    func statement(for edit: QueryRowEdit, in target: QueryEditTarget) throws -> String {
        let columns = target.columns
        guard edit.original.count == columns.count, !edit.values.isEmpty else {
            throw DatabaseError("Invalid result edit.")
        }
        let keyIndices = columns.indices.filter { columns[$0].isKey }
        guard !keyIndices.isEmpty, keyIndices.allSatisfy({ edit.original[$0] != nil }) else {
            throw DatabaseError("A complete primary key is required to edit a result row.")
        }
        let d = SQLDialect(flavor: .postgres)
        // E strings are independent of standard_conforming_strings, including backslashes in pasted values.
        func literal(_ value: String?, column: QueryEditTarget.Column) throws -> String {
            guard let value else {
                return "NULL"
            }
            guard !value.contains("\0") else {
                throw DatabaseError("PostgreSQL text values cannot contain a NUL character.")
            }
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
            guard let type = Self.castTypes[column.typeOID] else {
                throw DatabaseError("This column type cannot safely be used in a result update.")
            }
            return "E'\(escaped)'::pg_catalog.\(type)"
        }
        var assignments: [String] = []
        for (index, value) in edit.values.sorted(by: { $0.key < $1.key }) {
            guard columns.indices.contains(index), columns[index].editable, !columns[index].isKey else {
                throw DatabaseError("This result column is read-only.")
            }
            assignments.append(
                "\(d.quoteIdentifier(columns[index].name)) = \(try literal(value, column: columns[index]))"
            )
        }
        // Match the old edited values too: don't silently overwrite a concurrent change.
        let matched = Set(keyIndices).union(edit.values.keys).sorted()
        let predicate =
            try matched.map { index in
                "\(d.quoteIdentifier(columns[index].name)) IS NOT DISTINCT FROM \(try literal(edit.original[index], column: columns[index]))"
            }
            .joined(separator: " AND ")
        return
            "UPDATE ONLY \(d.qualified(target.table)) SET \(assignments.joined(separator: ", ")) WHERE \(predicate) RETURNING "
            + columns.map { d.quoteIdentifier($0.name) }.joined(separator: ", ")
    }
}

extension PostgresDriver {
    public func queryEditTarget(for result: QueryResult) async throws -> QueryEditTarget? {
        guard let source = EditableSelect.source(result.statement), !result.origins.isEmpty,
            result.origins.count == result.columns.count, let oid = result.origins.first?.tableOID, oid != 0,
            result.origins.allSatisfy({ $0.tableOID == oid && $0.attribute > 0 }),
            Set(result.origins.map(\.attribute)).count == result.origins.count
        else { return nil }
        let named = source.map(dialect.quoteIdentifier).joined(separator: ".")
        let resolved = try await execute("SELECT pg_catalog.to_regclass(\(dialect.literal(named)))::oid::text")
        guard resolved.rows.first?.first == String(oid) else { return nil }
        let relation = try await execute(
            """
            SELECT n.nspname, c.relname FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.oid = \(oid) AND c.relkind = 'r' AND NOT c.relrowsecurity
              AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_inherits WHERE inhparent=c.oid OR inhrelid=c.oid)
              AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_rewrite WHERE ev_class=c.oid)
            """
        )
        .rows
        guard let table = relation.first, let schema = table[0], let name = table[1] else { return nil }
        let catalog = try await execute(
            """
            SELECT a.attnum::text, a.attname, a.atttypid::text,
                   pg_catalog.format_type(a.atttypid, NULL) AS type_name,
                   EXISTS (SELECT 1 FROM pg_catalog.pg_index i WHERE i.indrelid=a.attrelid AND i.indisprimary
                           AND i.indisvalid AND EXISTS (SELECT 1 FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, position)
                               WHERE k.position <= i.indnkeyatts AND k.attnum=a.attnum)) AS is_key,
                   a.attgenerated <> '' AS generated
            FROM pg_catalog.pg_attribute a WHERE a.attrelid=\(oid) AND a.attnum>0 AND NOT a.attisdropped
            """
        )
        .rows
        var columns: [Int16: QueryEditTarget.Column] = [:]
        for row in catalog {
            guard let attribute = row[0].flatMap(Int16.init), let name = row[1], let type = row[2].flatMap(UInt32.init),
                let typeName = row[3]
            else { continue }
            let key = row[4] == "true"
            columns[attribute] = .init(
                name: name,
                attribute: attribute,
                typeOID: type,
                typeName: typeName,
                isKey: key,
                editable: !key && row[5] == "false" && PostgresResultEditWriter.scalarTypes.contains(type)
            )
        }
        let keys = columns.values.filter(\.isKey)
        guard !keys.isEmpty, keys.allSatisfy({ PostgresResultEditWriter.scalarTypes.contains($0.typeOID) }) else {
            return nil
        }
        let present = Set(result.origins.map(\.attribute))
        guard keys.allSatisfy({ present.contains($0.attribute) }) else { return nil }
        let mapped = result.origins.compactMap { columns[$0.attribute] }
        guard mapped.count == result.columns.count, mapped.contains(where: \.editable) else { return nil }
        return QueryEditTarget(
            table: TableRef(schema: schema, name: name),
            tableOID: oid,
            columns: mapped,
            writer: PostgresResultEditWriter()
        )
    }

    /// A separate session is supplied by the UI for commits, so no active user transaction is committed implicitly.
    public func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]] {
        guard !edits.isEmpty else {
            return [:]
        }
        let statements = try edits.map { try target.statement(for: $0) }
        _ = try await execute("BEGIN")
        do {
            _ = try await execute("SET LOCAL lock_timeout = '5s'")
            _ = try await execute("SET LOCAL statement_timeout = '15s'")
            _ = try await execute("LOCK TABLE ONLY \(dialect.qualified(target.table)) IN ROW EXCLUSIVE MODE")
            let check = try await execute(
                "SELECT \(dialect.literal(dialect.qualified(target.table)))::regclass::oid::text"
            )
            guard check.rows.first?.first == String(target.tableOID) else {
                throw DatabaseError("The source table changed. Run the query again before editing.")
            }
            // Revalidate under the table lock: DROP/ALTER/RLS changes after the result was displayed must not
            // turn a stale result into a write against a different shape of table.
            let projected = target.columns.map { dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
            let probe = try await execute("SELECT \(projected) FROM \(dialect.qualified(target.table)) LIMIT 0")
            guard let current = try await queryEditTarget(for: probe), current.tableOID == target.tableOID,
                current.columns == target.columns
            else { throw DatabaseError("The source table changed. Run the query again before editing.") }
            var returned: [Int: [String?]] = [:]
            for (edit, sql) in zip(edits, statements) {
                let result = try await execute(sql)
                guard result.rows.count == 1 else {
                    throw DatabaseError(
                        "The row changed or was removed since this query ran. Nothing was saved; run the query again."
                    )
                }
                returned[edit.row] = result.rows[0]
            }
            _ = try await execute("COMMIT")
            return returned
        } catch {
            _ = try? await execute("ROLLBACK")
            throw error
        }
    }
}
