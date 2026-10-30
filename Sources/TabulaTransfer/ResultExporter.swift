import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, tsv, json, sqlInsert

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .sqlInsert: "SQL INSERT"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .json: "json"
        case .sqlInsert: "sql"
        }
    }
}

public enum ResultExporter {
    /// JSON keys must be unique, but joins often repeat a column name: "id", "id_2", ... A suffixed name skips any
    /// name another column already has.
    static func uniqueNames(_ columns: [String]) -> [String] {
        var taken: Set<String> = []
        var names: [String] = []
        for name in columns {
            guard taken.contains(name) else {
                taken.insert(name)
                names.append(name)
                continue
            }
            var number = 2
            while taken.contains("\(name)_\(number)") || columns.contains("\(name)_\(number)") {
                number += 1
            }
            taken.insert("\(name)_\(number)")
            names.append("\(name)_\(number)")
        }
        return names
    }

    /// `dialect` writes the INSERT statements of `.sqlInsert`; the other formats don't depend on the database.
    public static func export(
        columns: [String],
        rows: [[String?]],
        format: ExportFormat,
        table: TableRef? = nil,
        binaryColumns: Set<Int>,
        dialect: any QueryDialect
    ) throws -> String {
        switch format {
        case .csv:
            return delimited(columns: columns, rows: rows, separator: ",")
        case .tsv:
            return delimited(columns: columns, rows: rows, separator: "\t")
        case .json:
            let keys = uniqueNames(columns)
            let objects: [[String: Any]] = rows.map { row in
                var object: [String: Any] = [:]
                for (column, value) in zip(keys, row) {
                    object[column] = value ?? NSNull()
                }
                return object
            }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        case .sqlInsert:
            let target = table ?? TableRef(schema: "main", name: "results")
            let binary = Set(binaryColumns.compactMap { columns.indices.contains($0) ? columns[$0] : nil })
            return
                rows.map { row in
                    dialect.insert(target, values: Array(zip(columns, row)).map { ($0.0, $0.1) }, binaryColumns: binary)
                        + ";"
                }
                .joined(separator: "\n")
        }
    }

    private static func delimited(columns: [String], rows: [[String?]], separator: Character) -> String {
        func escape(_ value: String?) -> String {
            guard let value else { return "" }
            if value.contains(separator) || value.contains("\"") || value.contains(where: \.isNewline) {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }
        let sep = String(separator)
        return ([columns.map(escape).joined(separator: sep)] + rows.map { $0.map(escape).joined(separator: sep) })
            .joined(separator: "\n") + "\n"
    }
}
