import Foundation
import MongoClient
import MongoKitten

/// A MongoDB connection behind the same interface as the SQL drivers: databases are schemas, collections are
/// tables, and `execute` runs shell statements (`db.users.find({…})`), so the sidebar, grid, query tabs and
/// console work unchanged.
public actor MongoDriver: DatabaseDriver {
    public nonisolated let kind = DatabaseKind.mongodb
    public nonisolated let dialect: any QueryDialect = MongoQueryDialect()
    public nonisolated let catalog: any DatabaseCatalog = MongoCatalog()
    private let cluster: MongoCluster
    /// The database `db` refers to; `use` changes it.
    private var currentDatabase: String
    /// Field order learned per collection ("db.collection"), so pages show columns in a steady order.
    private var fieldOrder: [String: [String]] = [:]

    private init(cluster: MongoCluster, database: String) {
        self.cluster = cluster
        self.currentDatabase = database
    }

    public static func connect(_ config: ConnectionConfig, password: String?) async throws -> MongoDriver {
        let timeout = config.timeout
        // Seed lists are resolved and checked here rather than by the driver, which would accept any answer.
        let members = config.srv == true
            ? try await MongoSRV.resolve(config.resolvedHost, timeout: timeout).map { ConnectionSettings.Host(hostname: $0.host, port: $0.port) }
            : nil
        let settings = try settings(for: config, password: password, members: members)
        let cluster = try await withTimeout(seconds: timeout, "Connecting to MongoDB", discard: { cluster in
            Task { await cluster.disconnect() }
        }) {
            try await openCluster(settings)
        }
        let database = config.database.trimmingCharacters(in: .whitespaces)
        let driver = MongoDriver(cluster: cluster, database: database.isEmpty ? Defaults.Mongo.defaultDatabase : database)
        do {
            // Fails fast on a wrong password, which the cluster only finds out on first use.
            _ = try await driver.command(["ping": Int32(1)], in: Defaults.Mongo.authDatabase)
        } catch {
            await cluster.disconnect()
            throw error
        }
        return driver
    }

    /// `members`: the servers a seed list resolved to (`MongoSRV`); nil reads them from the host field.
    /// The cluster opens through the first member it tries and gives up if that one is down, so with several
    /// members each is tried in turn; the one that answers tells the cluster about the rest.
    private static func openCluster(_ settings: ConnectionSettings) async throws -> MongoCluster {
        do {
            return try await MongoCluster(connectingTo: settings)
        } catch where settings.hosts.count > 1 {
            var failures: [String] = [readable(error)]
            for host in settings.hosts {
                var single = settings
                single.hosts = [host]
                do {
                    return try await MongoCluster(connectingTo: single)
                } catch {
                    failures.append(readable(error))
                }
            }
            throw DatabaseError("Couldn't reach any member: " + Array(Set(failures)).sorted().joined(separator: "; "))
        } catch {
            throw DatabaseError(readable(error))
        }
    }

    /// NIO's connection errors print as nested structures; this gives "host:port: Connection refused".
    static func readable(_ error: any Error) -> String {
        guard let connection = error as? NIOConnectionError else { return error.localizedDescription }
        let causes = connection.connectionErrors.map { failure -> String in
            let reason = (failure.error as? IOError).map { String(cString: strerror($0.errnoCode)) } ?? String(describing: failure.error)
            return reason
        }
        let dns = [connection.dnsAError, connection.dnsAAAAError].compactMap { $0 }
        let reason = causes.first ?? dns.first.map { "can't resolve the name (\($0))" } ?? "no connection"
        return "\(connection.host):\(connection.port): \(reason)"
    }

    static func settings(for config: ConnectionConfig, password: String?, members: [ConnectionSettings.Host]? = nil) throws -> ConnectionSettings {
        let authentication: ConnectionSettings.Authentication = config.user.isEmpty
            ? .unauthenticated : .auto(username: config.user, password: password ?? "")
        let source = config.authSource?.trimmingCharacters(in: .whitespaces)
        let authSource = source?.isEmpty == false ? source : Defaults.Mongo.authDatabase
        let timeout = config.timeout
        let host = config.resolvedHost
        let database = config.database.isEmpty ? Defaults.Mongo.defaultDatabase : config.database
        // "a:27017,b:27017" lists the members of a replica set.
        let hosts = try members ?? host.split(separator: ",").map { part -> ConnectionSettings.Host in
            let text = part.trimmingCharacters(in: .whitespaces)
            if text.contains(":") { return try ConnectionSettings.Host(text, srv: false) }
            return ConnectionSettings.Host(hostname: text, port: config.port)
        }
        guard !hosts.isEmpty else { throw DatabaseError("Enter a host.") }
        return ConnectionSettings(authentication: authentication, authenticationSource: authSource, hosts: hosts, targetDatabase: database,
                                  useSSL: config.tls != .disable, verifySSLCertificates: config.tls == .verifyFull,
                                  connectTimeout: timeout, applicationName: Defaults.applicationName)
    }

    public func close() async {
        await cluster.disconnect()
    }

    // MARK: Catalog

    public func schemas() async throws -> [String] {
        let names: [String]
        do {
            let reply = try await command(["listDatabases": Int32(1), "nameOnly": true, "authorizedDatabases": true], in: Defaults.Mongo.authDatabase)
            names = (reply["databases"] as? Document)?.values.compactMap { ($0 as? Document)?["name"] as? String } ?? []
        } catch {
            // Users without listDatabases still see the database they connected to.
            names = []
        }
        return Set(names + [currentDatabase]).sorted()
    }

    public func defaultSchema() async throws -> String { currentDatabase }

    public func tables(in schema: String) async throws -> [TableRef] {
        let documents = try await cursor(["listCollections": Int32(1), "authorizedCollections": true, "nameOnly": false], in: schema)
        return documents.compactMap { document -> TableRef? in
            // system.views, system.profile…: the server's own bookkeeping (still reachable from the shell).
            guard let name = document["name"] as? String, !name.hasPrefix("system.") else { return nil }
            return TableRef(schema: schema, name: name, kind: document["type"] as? String == "view" ? .view : .table)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Fields found in the first documents, `_id` first, with the types seen.
    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let sample = try await cursor(["find": table.name, "limit": Int32(Defaults.Mongo.sampleSize),
                                       "batchSize": Int32(Defaults.Mongo.sampleSize)], in: table.schema)
        var order: [String] = ["_id"]
        var types: [String: [String: Int]] = [:]
        var present: [String: Int] = [:]
        for document in sample {
            for pair in document.pairs {
                if !order.contains(pair.key) { order.append(pair.key) }
                types[pair.key, default: [:]][MongoShell.typeName(pair.value), default: 0] += 1
                if !(pair.value is Null) { present[pair.key, default: 0] += 1 }
            }
        }
        if sample.isEmpty || types["_id"] == nil { order.removeFirst() }
        fieldOrder[table.id] = order
        return order.map { field in
            let seen = (types[field] ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
            return ColumnInfo(name: field, dataType: seen.isEmpty ? "unknown" : seen.joined(separator: " | "),
                              isNullable: (present[field] ?? 0) < sample.count, defaultValue: nil, isPrimaryKey: field == "_id")
        }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        guard table.kind == .table else { return [] }
        return try await cursor(["listIndexes": table.name], in: table.schema).compactMap { index in
            guard let name = index["name"] as? String, let key = index["key"] as? Document else { return nil }
            var options: [String] = []
            for option in ["unique", "sparse", "hidden"] where index[option] as? Bool == true { options.append(option) }
            if let seconds = index["expireAfterSeconds"] { options.append("expireAfterSeconds: \(MongoShell.format(seconds))") }
            if let filter = index["partialFilterExpression"] { options.append("partial: \(MongoShell.format(filter))") }
            let definition = MongoShell.format(key) + (options.isEmpty ? "" : " " + options.joined(separator: ", "))
            return IndexInfo(name: name, columns: key.keys, isUnique: name == "_id_" || index["unique"] as? Bool == true,
                             isPrimary: name == "_id_", definition: definition)
        }
    }

    // MARK: Statements

    public func execute(_ text: String) async throws -> QueryResult {
        let started = Date()
        let statement = try MongoStatement.parse(text)
        var result = try await run(statement)
        result.duration = Date().timeIntervalSince(started)
        result.statement = text
        return result
    }

    private func run(_ statement: MongoStatement) async throws -> QueryResult {
        let database = statement.database ?? currentDatabase
        switch statement.target {
        case .use(let name):
            currentDatabase = name
            return QueryResult()
        case .show(let what):
            return try await show(what, in: database)
        case .database:
            return try await runDatabaseMethod(statement, in: database)
        case .collection(let name):
            return try await runCollectionMethod(statement, collection: name, in: database)
        }
    }

    private func show(_ what: String, in database: String) async throws -> QueryResult {
        switch what {
        case "dbs", "databases":
            let reply = try await command(["listDatabases": Int32(1), "authorizedDatabases": true], in: Defaults.Mongo.authDatabase)
            return documentsResult((reply["databases"] as? Document)?.values.compactMap { $0 as? Document } ?? [])
        case "collections", "tables":
            let names = try await tables(in: database).map(\.name)
            return QueryResult(columns: ["name"], rows: names.map { [$0] })
        case "users":
            return documentsResult(try await command(["usersInfo": Int32(1)], in: database)["users"].map(Self.documents) ?? [])
        case "roles":
            return documentsResult(try await command(["rolesInfo": Int32(1)], in: database)["roles"].map(Self.documents) ?? [])
        default:
            throw DatabaseError("Unknown “show \(what)”. Try show dbs, show collections, show users or show roles.")
        }
    }

    private func runDatabaseMethod(_ statement: MongoStatement, in database: String) async throws -> QueryResult {
        let call = statement.calls[0]
        let arguments = Arguments(call)
        switch call.name {
        case "runCommand", "adminCommand":
            let target = call.name == "adminCommand" ? Defaults.Mongo.authDatabase : database
            let command: Document
            if let name = arguments.values.first as? String {
                command = [name: Int32(1)]
            } else {
                command = try arguments.document(0, "the command")
            }
            return documentsResult([try await self.command(command, in: target, writable: true)])
        case "getCollectionNames":
            let names = try await tables(in: database).map(\.name)
            return QueryResult(columns: ["name"], rows: names.map { [$0] })
        case "getCollectionInfos":
            var command: Document = ["listCollections": Int32(1)]
            if let filter = arguments.optionalDocument(0) { command["filter"] = filter }
            return documentsResult(try await cursor(command, in: database))
        case "createCollection":
            var command: Document = ["create": try arguments.string(0, "a collection name")]
            command.append(contentsOf: arguments.optionalDocument(1) ?? Document())
            _ = try await self.command(command, in: database, writable: true)
            return QueryResult()
        case "createView":
            var command: Document = ["create": try arguments.string(0, "a view name"), "viewOn": try arguments.string(1, "the source collection"),
                                     "pipeline": try arguments.array(2, "a pipeline")]
            command.append(contentsOf: arguments.optionalDocument(3) ?? Document())
            _ = try await self.command(command, in: database, writable: true)
            return QueryResult()
        case "dropDatabase":
            _ = try await command(["dropDatabase": Int32(1)], in: database, writable: true)
            return QueryResult()
        case "stats":
            return documentsResult([try await command(["dbStats": Int32(1)], in: database)])
        case "serverStatus":
            return documentsResult([try await command(["serverStatus": Int32(1)], in: Defaults.Mongo.authDatabase)])
        case "hostInfo":
            return documentsResult([try await command(["hostInfo": Int32(1)], in: Defaults.Mongo.authDatabase)])
        case "hello", "isMaster":
            return documentsResult([try await command(["hello": Int32(1)], in: Defaults.Mongo.authDatabase)])
        case "listCommands":
            return documentsResult([try await command(["listCommands": Int32(1)], in: Defaults.Mongo.authDatabase)])
        case "version":
            let info = try await command(["buildInfo": Int32(1)], in: Defaults.Mongo.authDatabase)
            return QueryResult(columns: ["version"], rows: [[info["version"] as? String]])
        case "getName":
            return QueryResult(columns: ["name"], rows: [[database]])
        case "getUsers":
            return documentsResult(try await command(["usersInfo": Int32(1)], in: database)["users"].map(Self.documents) ?? [])
        case "getRoles":
            return documentsResult(try await command(["rolesInfo": Int32(1)], in: database)["roles"].map(Self.documents) ?? [])
        case "getProfilingStatus":
            return documentsResult([try await command(["profile": Int32(-1)], in: database)])
        case "currentOp":
            let pipeline: Document = [["$currentOp": arguments.optionalDocument(0) ?? Document()] as Document]
            return documentsResult(try await cursor(["aggregate": Int32(1), "pipeline": pipeline, "cursor": Document()], in: Defaults.Mongo.authDatabase))
        case "aggregate":
            var pipeline = try arguments.array(0, "a pipeline")
            if let limit = try limit(of: statement) { pipeline.append(["$limit": limit] as Document) }
            return documentsResult(try await cursor(["aggregate": Int32(1), "pipeline": pipeline, "cursor": Document()], in: database,
                                                    limit: try limit(of: statement).map(Int.init)))
        default:
            throw DatabaseError("db.\(call.name)() isn't supported. Use db.runCommand({ … }) for other commands.")
        }
    }

    private func runCollectionMethod(_ statement: MongoStatement, collection: String, in database: String) async throws -> QueryResult {
        let call = statement.calls[0]
        let arguments = Arguments(call)
        switch call.name {
        case "find", "findOne":
            var command: Document = ["find": collection, "filter": arguments.optionalDocument(0) ?? Document()]
            if let projection = arguments.optionalDocument(1) { command["projection"] = projection }
            command.append(contentsOf: arguments.optionalDocument(2) ?? Document())
            for modifier in statement.calls.dropFirst() {
                let value = modifier.arguments.first
                switch modifier.name {
                case "sort", "projection", "project", "hint", "collation", "maxTimeMS", "skip", "limit", "batchSize", "comment",
                     "allowDiskUse", "min", "max", "returnKey", "showRecordId":
                    guard let value else { throw DatabaseError(".\(modifier.name)() needs an argument.") }
                    command[modifier.name == "project" ? "projection" : modifier.name] = value
                case "count", "size", "itcount":
                    let filter = command["filter"] as? Document ?? Document()
                    return countResult(try await countDocuments(collection, in: database, filter: filter,
                                                                skip: command["skip"], limit: command["limit"]))
                case "explain":
                    return documentsResult([try await explain(command, verbosity: value as? String, in: database)])
                case "toArray", "pretty", "noCursorTimeout":
                    break
                default:
                    throw DatabaseError(".\(modifier.name)() isn't supported after find().")
                }
            }
            if call.name == "findOne" { command["limit"] = Int32(1); command["singleBatch"] = true }
            let limit = (command["limit"]).flatMap(MongoShellParser.double).map { Int($0) }
            let documents = try await cursor(command, in: database, limit: limit)
            return documentsResult(documents, order: fieldOrder["\(database).\(collection)"] ?? [])
        case "aggregate":
            var pipeline = try arguments.array(0, "a pipeline")
            var command: Document = ["aggregate": collection, "cursor": Document()]
            command.append(contentsOf: arguments.optionalDocument(1) ?? Document())
            let limit = try limit(of: statement)
            // A stage can't follow $out or $merge; their results aren't shown anyway.
            let writes = pipeline.values.last.map { ($0 as? Document)?.keys.first.map { $0 == "$out" || $0 == "$merge" } ?? false } ?? false
            if let limit, !writes { pipeline.append(["$limit": limit] as Document) }
            command["pipeline"] = pipeline
            if statement.modifier("explain") != nil {
                return documentsResult([try await explain(command, verbosity: statement.modifier("explain")?.arguments.first as? String, in: database)])
            }
            return documentsResult(try await cursor(command, in: database, writable: writes, limit: limit.map(Int.init)))
        case "countDocuments":
            let options = arguments.optionalDocument(1) ?? Document()
            return countResult(try await countDocuments(collection, in: database, filter: arguments.optionalDocument(0) ?? Document(),
                                                        skip: options["skip"], limit: options["limit"]))
        case "estimatedDocumentCount", "count":
            var command: Document = ["count": collection]
            if call.name == "count", let filter = arguments.optionalDocument(0) { command["query"] = filter }
            let reply = try await self.command(command, in: database)
            return countResult(reply["n"].flatMap(MongoShellParser.double).map { Int($0) } ?? 0)
        case "distinct":
            let field = try arguments.string(0, "a field name")
            var command: Document = ["distinct": collection, "key": field]
            if let filter = arguments.optionalDocument(1) { command["query"] = filter }
            let values = (try await self.command(command, in: database)["values"] as? Document)?.values ?? []
            return QueryResult(columns: [field], rows: values.map { [MongoShell.cell($0)] }, documents: DocumentTexts(values))
        case "insertOne", "insert", "insertMany":
            let documents: [Document]
            if call.name == "insertOne" {
                documents = [try arguments.document(0, "a document")]
            } else if let array = arguments.values.first as? Document, array.isArray {
                documents = array.values.compactMap { $0 as? Document }
            } else {
                documents = [try arguments.document(0, "a document")]
            }
            let withIds = documents.map(Self.withId)
            var command: Document = ["insert": collection, "documents": Self.array(withIds)]
            command.append(contentsOf: arguments.optionalDocument(1) ?? Document())
            let reply = try await self.command(command, in: database, writable: true)
            let ids = withIds.compactMap { $0["_id"] }
            let summary: Document = call.name == "insertOne"
                ? ["acknowledged": true, "insertedId": ids.first ?? Null()]
                : ["acknowledged": true, "insertedCount": reply["n"] ?? Int32(ids.count), "insertedIds": Self.array(ids)]
            return documentsResult([summary], affected: reply["n"].flatMap(MongoShellParser.double).map { Int($0) })
        case "updateOne", "updateMany", "replaceOne", "update":
            let filter = try arguments.document(0, "a filter")
            guard let change = arguments.values.dropFirst().first as? Document else { throw DatabaseError("\(call.name) needs an update document.") }
            let operators = !change.isArray && change.keys.first?.hasPrefix("$") == true
            if call.name == "replaceOne", operators || change.isArray {
                throw DatabaseError("replaceOne takes a whole document; use updateOne for $set and other operators.")
            }
            if call.name == "updateOne" || call.name == "updateMany", !operators, !change.isArray {
                throw DatabaseError("\(call.name) needs update operators such as { $set: { … } }; use replaceOne to replace a document.")
            }
            let options = arguments.optionalDocument(2) ?? Document()
            var update: Document = ["q": filter, "u": change, "multi": call.name == "updateMany" || options["multi"] as? Bool == true]
            for key in ["upsert", "arrayFilters", "hint", "collation"] { if let value = options[key] { update[key] = value } }
            let reply = try await command(["update": collection, "updates": [update] as Document], in: database, writable: true)
            var summary: Document = ["acknowledged": true, "matchedCount": reply["n"] ?? Int32(0), "modifiedCount": reply["nModified"] ?? Int32(0)]
            if let upserted = (reply["upserted"] as? Document)?.values.first as? Document {
                summary["upsertedCount"] = Int32(1)
                summary["upsertedId"] = upserted["_id"] ?? Null()
                summary["matchedCount"] = Int32(0)
            }
            return documentsResult([summary], affected: summary["modifiedCount"].flatMap(MongoShellParser.double).map { Int($0) })
        case "deleteOne", "deleteMany", "remove":
            let filter = try arguments.document(0, "a filter")
            // remove(filter, true) and remove(filter, { justOne: true }) both delete one document.
            let second = arguments.values.dropFirst().first
            let justOne = call.name == "deleteOne"
                || (call.name == "remove" && (second as? Bool == true || (second as? Document)?["justOne"] as? Bool == true))
            var delete: Document = ["q": filter, "limit": Int32(justOne ? 1 : 0)]
            if let options = arguments.optionalDocument(1) {
                for key in ["hint", "collation"] { if let value = options[key] { delete[key] = value } }
            }
            let reply = try await command(["delete": collection, "deletes": [delete] as Document], in: database, writable: true)
            let count = reply["n"] ?? Int32(0)
            return documentsResult([["acknowledged": true, "deletedCount": count] as Document],
                                   affected: MongoShellParser.double(count).map { Int($0) })
        case "findOneAndUpdate", "findOneAndReplace", "findOneAndDelete":
            var command: Document = ["findAndModify": collection, "query": try arguments.document(0, "a filter")]
            let options: Document
            if call.name == "findOneAndDelete" {
                command["remove"] = true
                options = arguments.optionalDocument(1) ?? Document()
            } else {
                guard let change = arguments.values.dropFirst().first as? Document else { throw DatabaseError("\(call.name) needs an update.") }
                command["update"] = change
                options = arguments.optionalDocument(2) ?? Document()
                command["new"] = options["returnDocument"] as? String == "after" || options["returnNewDocument"] as? Bool == true
            }
            for key in ["sort", "upsert", "arrayFilters", "hint", "collation"] { if let value = options[key] { command[key] = value } }
            if let projection = options["projection"] { command["fields"] = projection }
            let reply = try await self.command(command, in: database, writable: true)
            return documentsResult((reply["value"] as? Document).map { [$0] } ?? [], affected: 1)
        case "createIndex", "createIndexes", "ensureIndex":
            let keys: [Document]
            if call.name == "createIndexes" {
                keys = try arguments.array(0, "an array of index keys").values.compactMap { $0 as? Document }
            } else {
                keys = [try arguments.document(0, "the index keys")]
            }
            let options = arguments.optionalDocument(1) ?? Document()
            let indexes = keys.map { key -> Document in
                var index: Document = ["key": key, "name": options["name"] as? String ?? Self.indexName(key)]
                for pair in options.pairs where pair.key != "name" { index[pair.key] = pair.value }
                return index
            }
            _ = try await command(["createIndexes": collection, "indexes": Self.array(indexes)], in: database, writable: true)
            return QueryResult(columns: ["name"], rows: indexes.map { [$0["name"] as? String] })
        case "dropIndex", "dropIndexes":
            let index: Primitive = arguments.values.first ?? "*"
            _ = try await command(["dropIndexes": collection, "index": index], in: database, writable: true)
            return documentsResult([["ok": Int32(1)] as Document])
        case "getIndexes":
            return documentsResult(try await cursor(["listIndexes": collection], in: database))
        case "drop":
            _ = try await command(["drop": collection], in: database, writable: true)
            return QueryResult()
        case "renameCollection":
            let target = try arguments.string(0, "the new name")
            _ = try await command(["renameCollection": "\(database).\(collection)", "to": "\(database).\(target)",
                                   "dropTarget": arguments.values.dropFirst().first as? Bool ?? false],
                                  in: Defaults.Mongo.authDatabase, writable: true)
            return QueryResult()
        case "stats":
            let pipeline: Document = [["$collStats": ["storageStats": Document(), "count": Document()] as Document] as Document]
            return documentsResult(try await cursor(["aggregate": collection, "pipeline": pipeline, "cursor": Document()], in: database))
        default:
            throw DatabaseError("\(call.name)() isn't supported. Use db.runCommand({ … }) for other commands.")
        }
    }

    // MARK: Helpers

    /// Runs a database command and returns its reply, throwing the server's message when it fails.
    func command(_ command: Document, in database: String, writable: Bool = false) async throws -> Document {
        let connection = try await cluster.next(for: writable ? .writable : .basic)
        return try await run(command, in: database, on: connection)
    }

    private func run(_ command: Document, in database: String, on connection: MongoConnection) async throws -> Document {
        let reply = try await connection.execute(command, namespace: MongoNamespace(to: "$cmd", inDatabase: database),
                                                 sessionId: connection.implicitSessionId)
        let document = try reply.getDocument()
        guard MongoShellParser.double(document["ok"] ?? Int32(0)) == 1 || document["ok"] as? Bool == true else {
            throw Self.error(from: document)
        }
        if let errors = document["writeErrors"] as? Document, let first = errors.values.first as? Document {
            throw Self.error(from: first, prefix: errors.count > 1 ? "\(errors.count) writes failed. First: " : "")
        }
        if let concern = document["writeConcernError"] as? Document {
            throw Self.error(from: concern, prefix: "Write concern: ")
        }
        return document
    }

    private static func error(from reply: Document, prefix: String = "") -> DatabaseError {
        let message = reply["errmsg"] as? String ?? "The command failed."
        let name = reply["codeName"] as? String
        return DatabaseError(prefix + message + (name.map { " (\($0))" } ?? ""))
    }

    /// Runs a command that opens a cursor and reads up to `limit` documents (at most `Defaults.Mongo.maxDocuments`),
    /// on one connection, since a cursor lives on the server that opened it.
    private func cursor(_ command: Document, in database: String, writable: Bool = false, limit: Int? = nil) async throws -> [Document] {
        let cap = min(limit.map { $0 > 0 ? $0 : Defaults.Mongo.maxDocuments } ?? Defaults.Mongo.maxDocuments, Defaults.Mongo.maxDocuments)
        let connection = try await cluster.next(for: writable ? .writable : .basic)
        let reply = try await run(command, in: database, on: connection)
        guard let cursor = reply["cursor"] as? Document else { return [] }
        var documents = Self.documents(cursor["firstBatch"] ?? Document())
        var id = cursor["id"].flatMap(Self.cursorID) ?? 0
        let namespace = cursor["ns"] as? String ?? ""
        let collection = namespace.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        while id != 0, documents.count < cap {
            let more = try await run(["getMore": id, "collection": collection,
                                      "batchSize": Int32(min(Defaults.Mongo.batchSize, cap - documents.count))], in: database, on: connection)
            guard let next = more["cursor"] as? Document else { break }
            documents += Self.documents(next["nextBatch"] ?? Document())
            id = next["id"].flatMap(Self.cursorID) ?? 0
        }
        if id != 0 {
            _ = try? await run(["killCursors": collection, "cursors": [id] as Document], in: database, on: connection)
        }
        return Array(documents.prefix(cap))
    }

    private static func cursorID(_ value: Primitive) -> Int? {
        switch value {
        case let int as Int: int
        case let int as Int32: Int(int)
        default: nil
        }
    }

    static func array(_ values: [Primitive]) -> Document {
        var array = Document(isArray: true)
        for value in values { array.append(value) }
        return array
    }

    static func documents(_ value: Primitive) -> [Document] {
        (value as? Document)?.values.compactMap { $0 as? Document } ?? []
    }

    private func countDocuments(_ collection: String, in database: String, filter: Document, skip: Primitive?, limit: Primitive?) async throws -> Int {
        var pipeline: Document = [["$match": filter] as Document]
        if let skip, MongoShellParser.double(skip) ?? 0 > 0 { pipeline.append(["$skip": skip] as Document) }
        if let limit, MongoShellParser.double(limit) ?? 0 > 0 { pipeline.append(["$limit": limit] as Document) }
        pipeline.append(["$group": ["_id": Int32(1), "n": ["$sum": Int32(1)] as Document] as Document] as Document)
        let result = try await cursor(["aggregate": collection, "pipeline": pipeline, "cursor": Document()], in: database)
        return result.first?["n"].flatMap(MongoShellParser.double).map { Int($0) } ?? 0
    }

    private func explain(_ command: Document, verbosity: String?, in database: String) async throws -> Document {
        var explained = command
        explained.removeValue(forKey: "singleBatch")
        return try await self.command(["explain": explained, "verbosity": verbosity ?? "queryPlanner"], in: database)
    }

    private func limit(of statement: MongoStatement) throws -> Int32? {
        guard let call = statement.modifier("limit") else { return nil }
        guard let value = call.arguments.first.flatMap(MongoShellParser.double), let limit = Int32(exactly: value) else {
            throw DatabaseError(".limit() needs a number.")
        }
        return limit > 0 ? limit : nil
    }

    /// The default name the server tools give an index: `name_1_age_-1`.
    static func indexName(_ key: Document) -> String {
        key.pairs.map { "\($0.key)_\(MongoShell.cell($0.value) ?? "")" }.joined(separator: "_")
    }

    /// Inserts get their `_id` here (first, as the server would place it), so the result can show it.
    private static func withId(_ document: Document) -> Document {
        guard document["_id"] == nil else { return document }
        var withId: Document = ["_id": ObjectId()]
        withId.append(contentsOf: document)
        return withId
    }

    private func countResult(_ count: Int) -> QueryResult {
        QueryResult(columns: ["count"], rows: [[String(count)]])
    }

    /// Documents as rows: one column per top-level field (`order` first, then fields as they appear).
    private func documentsResult(_ documents: [Document], order: [String] = [], affected: Int? = nil) -> QueryResult {
        var columns: [String] = []
        var known = Set<String>()
        let present = Set(documents.flatMap(\.keys))
        for field in order where present.contains(field) && known.insert(field).inserted { columns.append(field) }
        for document in documents {
            for key in document.keys where known.insert(key).inserted { columns.append(key) }
        }
        if documents.isEmpty, !order.isEmpty { columns = order }
        let rows = documents.map { document in columns.map { document[$0].flatMap(MongoShell.cell) } }
        return QueryResult(columns: columns, rows: rows, affectedRows: affected, documents: DocumentTexts(documents))
    }
}

/// The arguments of one shell call, read by position.
private struct Arguments {
    let call: MongoStatement.Call
    var values: [Primitive] { call.arguments }

    init(_ call: MongoStatement.Call) { self.call = call }

    func optionalDocument(_ position: Int) -> Document? {
        guard values.indices.contains(position), let document = values[position] as? Document, !document.isArray else { return nil }
        return document
    }

    func document(_ position: Int, _ what: String) throws -> Document {
        guard let document = optionalDocument(position) else { throw DatabaseError("\(call.name)() needs \(what) like { field: value }.") }
        return document
    }

    func array(_ position: Int, _ what: String) throws -> Document {
        guard values.indices.contains(position), let array = values[position] as? Document, array.isArray else {
            throw DatabaseError("\(call.name)() needs \(what) like [ … ].")
        }
        return array
    }

    func string(_ position: Int, _ what: String) throws -> String {
        guard values.indices.contains(position), let string = values[position] as? String else {
            throw DatabaseError("\(call.name)() needs \(what) in quotes.")
        }
        return string
    }
}
