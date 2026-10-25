import TabulaCore

/// The words each database uses, so labels say "collection" and "document" for MongoDB.
extension DatabaseKind {
    var tablesTitle: String { isDocument ? "Collections" : "Tables" }
    var tableNoun: String { isDocument ? "collection" : "table" }
    var rowNoun: String { isDocument ? "document" : "row" }
    /// What the sidebar's picker chooses between.
    var schemaNoun: String { self == .mysql || isDocument ? "Database" : "Schema" }
    /// The language of the query editor and generated statements.
    var languageName: String { isDocument ? "MongoDB shell" : "SQL" }
    /// Short form for buttons ("Preview SQL", "Preview Commands").
    var statementsNoun: String { isDocument ? "Commands" : "SQL" }
    var truncateTitle: String { isDocument ? "Delete All Documents" : "Truncate" }
    /// Functions, procedures and triggers live in SQL databases only.
    var supportsRoutines: Bool { self != .redis && !isDocument }
    /// Foreign keys, which the relationship diagram draws.
    var supportsDiagram: Bool { self != .redis && !isDocument }
}
