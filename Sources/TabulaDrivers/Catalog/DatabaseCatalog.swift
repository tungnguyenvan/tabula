import Foundation
import TabulaFoundation
import TabulaSQL

/// What a database tells about itself beyond tables and columns: its version, its schemas and other databases,
/// foreign keys, live metrics and stored routines.
///
/// Each engine supplies its own (a strategy), and a driver hands out the one for its database. The catalog runs its
/// queries through the driver it is given rather than its own connection, so decorators around the driver (the
/// console log, the SSH tunnel check) see every query.
public protocol DatabaseCatalog: Sendable {
    /// The server's name and version, such as "PostgreSQL 16.11 on aarch64…".
    func serverVersion(on driver: any DatabaseDriver) async throws -> String
    /// Makes `schema` the one unqualified names refer to, as the sidebar's schema picker promises.
    func useSchema(_ schema: String, on driver: any DatabaseDriver) async throws
    /// The other databases this login may open, where a connection reaches one database at a time (PostgreSQL).
    /// Empty where databases are listed as schemas (MySQL, MongoDB) or there is one file (SQLite).
    func serverDatabases(on driver: any DatabaseDriver) async throws -> [String]
    /// The database the connection is in, where that differs from the schemas it lists (PostgreSQL); nil elsewhere.
    func currentDatabase(on driver: any DatabaseDriver) async throws -> String?
    /// Foreign keys of the tables in `schema`. Document databases have none.
    func foreignKeys(in schema: String, on driver: any DatabaseDriver) async throws -> [ForeignKeyInfo]
    /// One sample of the server's counters, gauges and largest tables.
    func metrics(schema: String, on driver: any DatabaseDriver) async throws -> MetricsSample
    /// Functions, procedures and triggers; nil where the database stores none (MongoDB).
    var routines: (any RoutineCatalog)? { get }

    /// Makes a session read-only where the server can enforce it, and bounds each statement's time.
    func prepareReadOnlySession(timeoutSeconds: Int, on driver: any DatabaseDriver) async throws
    /// The statements that open a read-only transaction for one statement (ended with ROLLBACK), or nil where the
    /// database has no such transaction.
    func readOnlyTransaction(timeoutSeconds: Int) -> [String]?
}

/// A database's functions, procedures and triggers: listing, reading and replacing their definitions.
public protocol RoutineCatalog: Sendable {
    /// The kinds this database stores (SQLite has triggers only).
    var kinds: [RoutineInfo.Kind] { get }
    /// The routines in `schema`. PostgreSQL functions that belong to an extension are left out.
    func routines(in schema: String, on driver: any DatabaseDriver) async throws -> [RoutineInfo]
    /// The statement that creates the routine as it is now.
    func definition(of routine: RoutineInfo, on driver: any DatabaseDriver) async throws -> String
    /// The statement that removes the routine.
    func dropStatement(for routine: RoutineInfo) -> String
    /// Replaces the routine with `newDefinition` (a full CREATE statement), keeping `original` when that fails.
    func replace(_ routine: RoutineInfo, original: String, with newDefinition: String, on driver: any DatabaseDriver) async throws
    /// A starting point for a new routine.
    func template(for kind: RoutineInfo.Kind, schema: String, table: String?) -> String
}

extension DatabaseDriver {
    public func serverVersion() async throws -> String { try await catalog.serverVersion(on: self) }

    public func useSchema(_ schema: String) async throws {
        guard !schema.isEmpty else { return }
        try await catalog.useSchema(schema, on: self)
    }

    public func serverDatabases() async throws -> [String] { try await catalog.serverDatabases(on: self) }
    public func currentDatabase() async throws -> String? { try await catalog.currentDatabase(on: self) }
    public func foreignKeys(in schema: String) async throws -> [ForeignKeyInfo] { try await catalog.foreignKeys(in: schema, on: self) }
    public func metrics(schema: String) async throws -> MetricsSample { try await catalog.metrics(schema: schema, on: self) }

    /// The first value of the first row, for queries that return one value.
    package func value(_ statement: String) async throws -> String? {
        try await execute(statement).rows.first?.first ?? nil
    }
}

package enum RoutineText {
    /// The server's definition, or why there is none: an account without the privilege gets nothing back.
    package static func required(_ text: String?, for routine: RoutineInfo) throws -> String {
        guard let text, !text.isEmpty else {
            throw DatabaseError("The server didn't return the definition of \(routine.name). The account may lack the privilege to see it.")
        }
        return text
    }
}
