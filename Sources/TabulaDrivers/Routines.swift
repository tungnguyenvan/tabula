import Foundation
import TabulaFoundation
import TabulaSQL

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

    public init(
        kind: Kind,
        schema: String,
        name: String,
        arguments: String = "",
        table: String? = nil,
        detail: String = "",
        oid: String? = nil
    ) {
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
    /// The database's functions, procedures and triggers, or nil where it stores none.
    public var routineCatalog: (any RoutineCatalog)? { catalog.routines }

    public func routines(in schema: String) async throws -> [RoutineInfo] {
        guard let routines = catalog.routines else { return [] }
        return try await routines.routines(in: schema, on: self)
    }

    public func definition(of routine: RoutineInfo) async throws -> String {
        try await requiredRoutines().definition(of: routine, on: self)
    }

    public func replace(_ routine: RoutineInfo, original: String, with newDefinition: String) async throws {
        try await requiredRoutines().replace(routine, original: original, with: newDefinition, on: self)
    }

    private func requiredRoutines() throws -> any RoutineCatalog {
        guard let routines = catalog.routines else { throw DatabaseError("\(kind.displayName) stores no routines.") }
        return routines
    }
}
