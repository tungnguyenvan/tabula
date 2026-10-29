import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
@preconcurrency import RediStack
import TabulaDrivers
import TabulaFoundation

public enum RedisKeyType: String, CaseIterable, Sendable {
    case string, hash, list, set, zset, stream
    case unknown = "none"

    public var displayName: String {
        switch self {
        case .string: "String"
        case .hash: "Hash"
        case .list: "List"
        case .set: "Set"
        case .zset: "Sorted Set"
        case .stream: "Stream"
        case .unknown: "Unknown"
        }
    }
}

/// A key or value as raw bytes, with a readable form.
public struct RedisBytes: Hashable, Sendable, Comparable {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public init(_ string: String) { self.bytes = Array(string.utf8) }

    /// The UTF-8 text, or nil for binary data.
    public var text: String? { String(bytes: bytes, encoding: .utf8) }
    public var isText: Bool { text != nil }

    /// Plain text when possible, otherwise redis-cli style escaped (without the surrounding quotes).
    public var display: String {
        if let text { return text }
        return String(RedisCommandLine.quoted(bytes).dropFirst().dropLast())
    }

    public static func < (lhs: RedisBytes, rhs: RedisBytes) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}

public struct RedisKeyInfo: Sendable, Equatable {
    public var key: RedisBytes
    public var type: RedisKeyType
    /// Milliseconds to expiry, nil when the key has no TTL.
    public var ttlMilliseconds: Int?
    /// Elements (or bytes for strings).
    public var length: Int
    public var memoryBytes: Int?
    public var encoding: String?
}

/// One row of the keys table.
public struct RedisKeySummary: Sendable, Equatable, Identifiable {
    public var key: RedisBytes
    public var type: RedisKeyType
    public var ttlMilliseconds: Int?
    /// Bytes for strings, elements for collections.
    public var length: Int
    /// A short, single-line rendering of the value.
    public var preview: String
    public var id: RedisBytes { key }
}

/// Values of one page of a key, shaped for a grid.
public struct RedisPage: Sendable {
    public var columns: [String]
    public var rows: [[RedisBytes]]
    /// Cursor (hash/set/zset scans) or next index (lists) / last id (streams); nil when everything is loaded.
    public var next: String?
}

public actor RedisDriver {
    /// PTTL's replies for a key without an expiry and for a missing key.
    static let noExpiryTTL = -1
    static let missingKeyTTL = -2

    private var connection: RedisConnection
    public private(set) var database: Int
    public nonisolated let serverDescription: String

    private init(connection: RedisConnection, database: Int, serverDescription: String) {
        self.connection = connection
        self.database = database
        self.serverDescription = serverDescription
    }

    public static func connect(_ config: ConnectionConfig, password: String?) async throws -> RedisDriver {
        var logger = Logger(label: "tabula.redis")
        logger.logLevel = .critical
        let host = config.resolvedHost
        let port = config.port
        let database = Int(config.database.trimmingCharacters(in: .whitespaces)) ?? 0
        let username = config.user.isEmpty ? nil : config.user
        let password = password?.isEmpty == true ? nil : password

        let sslContext = try config.tlsConfiguration().map { try NIOSSLContext(configuration: $0) }
        let serverName = config.serverName(usingTLS: sslContext != nil)

        do {
            let address = try await config.resolveAddress()
            let configuration = try RedisConnection.Configuration(
                address: address,
                username: username,
                password: password,
                initialDatabase: database == 0 ? nil : database,
                defaultLogger: logger
            )
            let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
            let box = try await withTimeout(
                seconds: config.timeout,
                "Connecting to \(host):\(port)",
                discard: { _ = $0.connection.close() }
            ) {
                // TLS sits in front of RediStack's RESP handlers when enabled.
                let bootstrap = ClientBootstrap(group: eventLoop)
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                    .connectTimeout(.milliseconds(Int64(config.timeout * 1000)))
                    .channelInitializer { channel in
                        do {
                            if let sslContext {
                                let handler = try NIOSSLClientHandler(context: sslContext, serverHostname: serverName)
                                try channel.pipeline.syncOperations.addHandler(handler)
                            }
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                        return channel.pipeline.addBaseRedisHandlers()
                    }
                let connection =
                    try await RedisConnection.make(
                        configuration: configuration,
                        boundEventLoop: eventLoop,
                        configuredTCPClient: bootstrap
                    )
                    .get()
                return ConnectionBox(connection: connection)
            }
            let connection = box.connection
            let info = try? await connection.send(command: "INFO", with: [RedisArgument.text("server").resp]).get()
            let version =
                (info?.string ?? "").split(separator: "\r\n").first { $0.hasPrefix("redis_version:") }
                .map { "Redis " + $0.dropFirst("redis_version:".count) } ?? "Redis"
            return RedisDriver(connection: connection, database: database, serverDescription: version)
        } catch {
            throw DatabaseError(describe(error))
        }
    }

    static func describe(_ error: any Error) -> String {
        if let redis = error as? RedisError { return redis.message.replacingOccurrences(of: "(Redis) ", with: "") }
        if let database = error as? DatabaseError { return database.message }
        if let ssl = error as? NIOSSLError { return "TLS error: \(ssl)" }
        return String(describing: error)
    }

    public func close() async {
        _ = try? await connection.close().get()
    }

    // MARK: Raw commands

    /// Sends one command. Redis errors are returned as `.error`, not thrown; transport failures throw.
    public func send(_ arguments: [[UInt8]]) async throws -> RedisReply {
        guard let name = arguments.first.flatMap({ String(bytes: $0, encoding: .utf8) }) else {
            throw DatabaseError("Empty command")
        }
        let rest = arguments.dropFirst()
            .map { bytes -> RESPValue in
                var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                return .bulkString(buffer)
            }
        do {
            let reply = Self.convert(try await connection.send(command: name, with: rest).get())
            if name.uppercased() == "SELECT", case .status = reply, arguments.count > 1,
                let index = Int(String(decoding: arguments[1], as: UTF8.self))
            {
                database = index
            }
            return reply
        } catch let error as RedisError {
            return .error(Self.describe(error))
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    public func send(_ arguments: String...) async throws -> RedisReply {
        try await send(arguments.map { Array($0.utf8) })
    }

    /// Like `send`, but a Redis error becomes a thrown error (for the browser's own commands).
    @discardableResult
    func run(_ arguments: [[UInt8]]) async throws -> RedisReply {
        let reply = try await send(arguments)
        if case .error(let message) = reply { throw DatabaseError(message) }
        return reply
    }

    @discardableResult
    func run(_ arguments: [RedisArgument]) async throws -> RedisReply {
        try await run(arguments.map(\.bytes))
    }

    static func convert(_ value: RESPValue) -> RedisReply {
        switch value {
        case .null: return .null
        case .simpleString(var buffer): return .status(buffer.readString(length: buffer.readableBytes) ?? "")
        case .bulkString(let buffer):
            guard var buffer else { return .null }
            return .bulk(buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .error(let error): return .error(describe(error))
        case .integer(let value): return .integer(value)
        case .array(let values): return .array(values.map(convert))
        }
    }

    // MARK: Databases

    /// Database indexes with their key counts (from INFO keyspace); empty databases are included up to the configured count.
    public func databases() async throws -> [(index: Int, keys: Int)] {
        var counts: [Int: Int] = [:]
        let info = try await run([.text("INFO"), .text("keyspace")]).string ?? ""
        for line in info.split(whereSeparator: \.isNewline) where line.hasPrefix("db") {
            // db0:keys=12,expires=0,avg_ttl=0
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0].dropFirst(2)),
                let keys = parts[1].split(separator: ",").first(where: { $0.hasPrefix("keys=") })
                    .flatMap({ Int($0.dropFirst(5)) })
            else { continue }
            counts[index] = keys
        }
        // CONFIG is often disabled on managed services; fall back to the default of 16.
        var total = Defaults.Redis.databaseCount
        if case .array(let items) = try await send("CONFIG", "GET", "databases"), items.count == 2,
            let value = items[1].int
        {
            total = value
        }
        let maxIndex = max(total - 1, counts.keys.max() ?? 0, database)
        return (0...maxIndex).map { ($0, counts[$0] ?? 0) }
    }

    public func select(_ index: Int) async throws {
        try await run([.text("SELECT"), .text(String(index))])
        database = index
    }

    // MARK: Keys

    /// One SCAN round-trip. Pass cursor "0" to start; the returned cursor is "0" when done.
    public func scan(
        cursor: String,
        match: String,
        type: RedisKeyType?,
        count: Int = Defaults.Redis.scanBatch
    ) async throws -> (cursor: String, keys: [RedisBytes]) {
        var arguments: [RedisArgument] = [
            .text("SCAN"), .text(cursor), .text("MATCH"), .text(match.isEmpty ? "*" : match), .text("COUNT"),
            .text(String(count)),
        ]
        if let type, type != .unknown { arguments += [.text("TYPE"), .text(type.rawValue)] }
        let reply = try await run(arguments).array
        guard reply.count == 2, let next = reply[0].string else { throw DatabaseError("Unexpected SCAN reply") }
        return (next, reply[1].array.compactMap(\.bytes).map(RedisBytes.init))
    }

    /// Scans until at least `limit` keys are collected or the keyspace is exhausted.
    public func scanKeys(
        from cursor: String = "0",
        match: String,
        type: RedisKeyType?,
        limit: Int = 500
    ) async throws -> (cursor: String, keys: [RedisBytes]) {
        var cursor = cursor
        var keys: [RedisBytes] = []
        var rounds = 0
        repeat {
            let page = try await scan(cursor: cursor, match: match, type: type)
            keys += page.keys
            cursor = page.cursor
            rounds += 1
        } while cursor != "0" && keys.count < limit && rounds < 200
        return (cursor, keys)
    }

    /// TYPE of many keys, pipelined over the connection.
    public func types(of keys: [RedisBytes]) async throws -> [RedisKeyType] {
        let futures = keys.map { key in
            connection.send(command: "TYPE", with: [RedisArgument.bytes(key.bytes).resp])
        }
        var types: [RedisKeyType] = []
        for future in futures {
            let reply = Self.convert(try await future.get())
            types.append(reply.string.flatMap(RedisKeyType.init(rawValue:)) ?? .unknown)
        }
        return types
    }

    /// Type, TTL, length and a value preview for many keys. Commands are pipelined: every request is
    /// written before any reply is awaited, so 500 keys cost a few round trips, not thousands.
    public func summaries(
        of keys: [RedisBytes],
        previewLength: Int = Defaults.Redis.previewLength
    ) async throws -> [RedisKeySummary] {
        guard !keys.isEmpty else { return [] }
        func send(_ arguments: [RedisArgument]) -> EventLoopFuture<RESPValue> {
            connection.send(command: arguments[0].text, with: arguments.dropFirst().map(\.resp))
        }
        let typeFutures = keys.map { send([.text("TYPE"), .bytes($0.bytes)]) }
        let ttlFutures = keys.map { send([.text("PTTL"), .bytes($0.bytes)]) }
        var types: [RedisKeyType] = []
        for future in typeFutures {
            types.append(Self.convert(try await future.get()).string.flatMap(RedisKeyType.init(rawValue:)) ?? .unknown)
        }
        let previewLimit = String(previewLength - 1)
        let requests: [(length: EventLoopFuture<RESPValue>?, value: EventLoopFuture<RESPValue>?)] = zip(keys, types)
            .map { key, type in
                let k = RedisArgument.bytes(key.bytes)
                switch type {
                case .string:
                    return (send([.text("STRLEN"), k]), send([.text("GETRANGE"), k, .text("0"), .text(previewLimit)]))
                case .hash:
                    return (
                        send([.text("HLEN"), k]), send([.text("HSCAN"), k, .text("0"), .text("COUNT"), .text("8")])
                    )
                case .list: return (send([.text("LLEN"), k]), send([.text("LRANGE"), k, .text("0"), .text("7")]))
                case .set:
                    return (
                        send([.text("SCARD"), k]), send([.text("SSCAN"), k, .text("0"), .text("COUNT"), .text("8")])
                    )
                case .zset:
                    return (
                        send([.text("ZCARD"), k]),
                        send([.text("ZRANGE"), k, .text("0"), .text("7"), .text("WITHSCORES")])
                    )
                case .stream:
                    return (
                        send([.text("XLEN"), k]),
                        send([.text("XREVRANGE"), k, .text("+"), .text("-"), .text("COUNT"), .text("1")])
                    )
                case .unknown: return (nil, nil)
                }
            }
        var summaries: [RedisKeySummary] = []
        for (index, key) in keys.enumerated() {
            let pttl = Self.convert(try await ttlFutures[index].get()).int ?? RedisDriver.missingKeyTTL
            var length = 0
            var value = RedisReply.null
            if let future = requests[index].length { length = Self.convert(try await future.get()).int ?? 0 }
            if let future = requests[index].value { value = Self.convert(try await future.get()) }
            // Keys that expired or were deleted since the scan (TYPE "none", PTTL -2) are dropped.
            guard types[index] != .unknown, pttl != RedisDriver.missingKeyTTL else { continue }
            summaries.append(
                RedisKeySummary(
                    key: key,
                    type: types[index],
                    ttlMilliseconds: pttl >= 0 ? pttl : nil,
                    length: length,
                    preview: Self.preview(type: types[index], reply: value, length: length, limit: previewLength)
                )
            )
        }
        return summaries
    }

    static func preview(type: RedisKeyType, reply: RedisReply, length: Int, limit: Int) -> String {
        func flat(_ bytes: [UInt8]) -> String {
            RedisBytes(bytes).display.replacingOccurrences(of: "\r\n", with: " ⏎ ")
                .replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        let more = { (shown: Int) in shown < length ? ", …" : "" }
        switch type {
        case .string:
            let text = flat(reply.bytes ?? [])
            return length > limit ? text + "…" : text
        case .hash:
            let items = reply.array.count == 2 ? reply.array[1].array.compactMap(\.bytes) : []
            let pairs = stride(from: 0, to: items.count - 1, by: 2).map { "\(flat(items[$0])): \(flat(items[$0 + 1]))" }
            return "{" + pairs.joined(separator: ", ") + more(pairs.count) + "}"
        case .list:
            let items = reply.array.compactMap(\.bytes).map(flat)
            return "[" + items.joined(separator: ", ") + more(items.count) + "]"
        case .set:
            let items = reply.array.count == 2 ? reply.array[1].array.compactMap(\.bytes).map(flat) : []
            return "{" + items.joined(separator: ", ") + more(items.count) + "}"
        case .zset:
            let items = reply.array.compactMap(\.bytes)
            let pairs = stride(from: 0, to: items.count - 1, by: 2)
                .map { "\(flat(items[$0])) (\(flat(items[$0 + 1])))" }
            return "[" + pairs.joined(separator: ", ") + more(pairs.count) + "]"
        case .stream:
            guard let entry = reply.array.first?.array, entry.count == 2, let id = entry[0].bytes else {
                return "(empty)"
            }
            let fields = entry[1].array.compactMap(\.bytes)
            let pairs = stride(from: 0, to: fields.count - 1, by: 2)
                .map { "\(flat(fields[$0]))=\(flat(fields[$0 + 1]))" }
            return "latest \(flat(id)): " + pairs.joined(separator: " ")
        case .unknown:
            return ""
        }
    }

    public func info(_ key: RedisBytes) async throws -> RedisKeyInfo {
        let k = RedisArgument.bytes(key.bytes)
        let type = try await run([.text("TYPE"), k]).string.flatMap(RedisKeyType.init(rawValue:)) ?? .unknown
        let pttl = try await run([.text("PTTL"), k]).int ?? RedisDriver.noExpiryTTL
        let lengthCommand: String? =
            switch type {
            case .string: "STRLEN"
            case .hash: "HLEN"
            case .list: "LLEN"
            case .set: "SCARD"
            case .zset: "ZCARD"
            case .stream: "XLEN"
            case .unknown: nil
            }
        var length = 0
        if let lengthCommand { length = try await run([.text(lengthCommand), k]).int ?? 0 }
        let memory = try? await run([.text("MEMORY"), .text("USAGE"), k]).int
        let encoding = try? await run([.text("OBJECT"), .text("ENCODING"), k]).string
        return RedisKeyInfo(
            key: key,
            type: type,
            ttlMilliseconds: pttl >= 0 ? pttl : nil,
            length: length,
            memoryBytes: memory,
            encoding: encoding
        )
    }

    // MARK: Reading values

    /// Strings above this size are shown truncated and are read-only.
    public static let maxEditableStringBytes = 1_048_576

    public func string(_ key: RedisBytes) async throws -> (value: RedisBytes, truncated: Bool) {
        let k = RedisArgument.bytes(key.bytes)
        let length = try await run([.text("STRLEN"), k]).int ?? 0
        if length > Self.maxEditableStringBytes {
            let prefix =
                try await run([.text("GETRANGE"), k, .text("0"), .text(String(Self.maxEditableStringBytes - 1))]).bytes
                ?? []
            return (RedisBytes(prefix), true)
        }
        return (RedisBytes(try await run([.text("GET"), k]).bytes ?? []), false)
    }

    /// One page of a collection. `next` is the token from the previous page (nil for the first page).
    public func page(
        _ key: RedisBytes,
        type: RedisKeyType,
        after next: String?,
        count: Int = Defaults.Redis.pageSize
    ) async throws -> RedisPage {
        let k = RedisArgument.bytes(key.bytes)
        switch type {
        case .hash, .set, .zset:
            let command = type == .hash ? "HSCAN" : type == .set ? "SSCAN" : "ZSCAN"
            var cursor = next ?? "0"
            var items: [RedisBytes] = []
            var rounds = 0
            // SCAN may return few or no elements per call; keep going to fill a page.
            repeat {
                let reply = try await run([.text(command), k, .text(cursor), .text("COUNT"), .text(String(count))])
                    .array
                guard reply.count == 2, let nextCursor = reply[0].string else {
                    throw DatabaseError("Unexpected \(command) reply")
                }
                items += reply[1].array.compactMap(\.bytes).map(RedisBytes.init)
                cursor = nextCursor
                rounds += 1
            } while cursor != "0" && items.count < count * (type == .set ? 1 : 2) && rounds < 50
            let rows: [[RedisBytes]] =
                type == .set
                ? items.map { [$0] }
                : stride(from: 0, to: items.count - 1, by: 2).map { [items[$0], items[$0 + 1]] }
            let columns = type == .hash ? ["field", "value"] : type == .set ? ["member"] : ["member", "score"]
            return RedisPage(columns: columns, rows: rows, next: cursor == "0" ? nil : cursor)
        case .list:
            let start = Int(next ?? "0") ?? 0
            let values = try await run([.text("LRANGE"), k, .text(String(start)), .text(String(start + count - 1))])
                .array.compactMap(\.bytes)
            let rows = values.enumerated().map { [RedisBytes(String(start + $0.offset)), RedisBytes($0.element)] }
            return RedisPage(
                columns: ["index", "value"],
                rows: rows,
                next: values.count == count ? String(start + count) : nil
            )
        case .stream:
            // Exclusive start "(id" needs Redis 6.2+.
            let start = next.map { "(" + $0 } ?? "-"
            let entries = try await run([
                .text("XRANGE"), k, .text(start), .text("+"), .text("COUNT"), .text(String(count)),
            ])
            .array
            var fieldNames: [String] = []
            var parsed: [(id: RedisBytes, fields: [String: RedisBytes])] = []
            for entry in entries {
                let parts = entry.array
                guard parts.count == 2, let id = parts[0].bytes else { continue }
                let values = parts[1].array.compactMap(\.bytes)
                var fields: [String: RedisBytes] = [:]
                for index in stride(from: 0, to: values.count - 1, by: 2) {
                    let name = RedisBytes(values[index]).display
                    if !fieldNames.contains(name) { fieldNames.append(name) }
                    fields[name] = RedisBytes(values[index + 1])
                }
                parsed.append((RedisBytes(id), fields))
            }
            let rows = parsed.map { entry in [entry.id] + fieldNames.map { entry.fields[$0] ?? RedisBytes("") } }
            return RedisPage(
                columns: ["id"] + fieldNames,
                rows: rows,
                next: entries.count == count ? parsed.last?.id.display : nil
            )
        case .string, .unknown:
            return RedisPage(columns: [], rows: [], next: nil)
        }
    }

    // MARK: Writing

    public func setString(_ key: RedisBytes, to value: RedisBytes, keepTTL: Bool = true) async throws {
        var arguments: [RedisArgument] = [.text("SET"), .bytes(key.bytes), .bytes(value.bytes)]
        if keepTTL { arguments.append(.text("KEEPTTL")) }
        try await run(arguments)
    }

    public func delete(_ keys: [RedisBytes]) async throws -> Int {
        guard !keys.isEmpty else { return 0 }
        return try await run([.text("DEL")] + keys.map { .bytes($0.bytes) }).int ?? 0
    }

    /// Renames without overwriting an existing key.
    public func rename(_ key: RedisBytes, to newKey: RedisBytes) async throws {
        let renamed = try await run([.text("RENAMENX"), .bytes(key.bytes), .bytes(newKey.bytes)]).int ?? 0
        if renamed == 0 { throw DatabaseError("A key named “\(newKey.display)” already exists.") }
    }

    /// Sets a TTL in seconds, or removes it when nil.
    public func setTTL(_ key: RedisBytes, seconds: Int?) async throws {
        if let seconds {
            guard seconds > 0 else { throw DatabaseError("TTL must be at least 1 second.") }
            try await run([.text("EXPIRE"), .bytes(key.bytes), .text(String(seconds))])
        } else {
            try await run([.text("PERSIST"), .bytes(key.bytes)])
        }
    }

    public func exists(_ key: RedisBytes) async throws -> Bool {
        (try await run([.text("EXISTS"), .bytes(key.bytes)]).int ?? 0) > 0
    }

    /// Adds an element to a collection key, creating it if needed.
    /// hash: [field, value] · list: [value] (appended) · set: [member] · zset: [member, score] · stream: [field, value, …]
    public func add(_ key: RedisBytes, type: RedisKeyType, values: [RedisBytes]) async throws {
        let k = RedisArgument.bytes(key.bytes)
        let v = values.map { RedisArgument.bytes($0.bytes) }
        switch type {
        case .string:
            guard let value = values.first else { return }
            try await setString(key, to: value, keepTTL: false)
        case .hash:
            guard v.count == 2 else { throw DatabaseError("A hash entry needs a field and a value.") }
            try await run([.text("HSET"), k] + v)
        case .list:
            guard let value = v.first else { return }
            try await run([.text("RPUSH"), k, value])
        case .set:
            guard let member = v.first else { return }
            try await run([.text("SADD"), k, member])
        case .zset:
            guard values.count == 2, let score = values[1].text, Double(score) != nil else {
                throw DatabaseError("A sorted set entry needs a member and a numeric score.")
            }
            try await run([.text("ZADD"), k, .text(score), v[0]])
        case .stream:
            guard !v.isEmpty, v.count % 2 == 0 else { throw DatabaseError("A stream entry needs field/value pairs.") }
            try await run([.text("XADD"), k, .text("*")] + v)
        case .unknown:
            throw DatabaseError("Unsupported key type.")
        }
    }

    /// Changes one element. For hashes `old` is the field; for lists the index; for sets/zsets the member.
    public func update(
        _ key: RedisBytes,
        type: RedisKeyType,
        element old: RedisBytes,
        column: Int,
        to newValue: RedisBytes,
        row: [RedisBytes]
    ) async throws {
        let k = RedisArgument.bytes(key.bytes)
        switch (type, column) {
        case (.hash, 1):
            try await run([.text("HSET"), k, .bytes(old.bytes), .bytes(newValue.bytes)])
        case (.hash, 0):
            // Rename a field atomically, refusing to overwrite another field.
            if (try await run([.text("HEXISTS"), k, .bytes(newValue.bytes)]).int ?? 0) == 1 {
                throw DatabaseError("Field “\(newValue.display)” already exists.")
            }
            try await transaction([
                [.text("HSET"), k, .bytes(newValue.bytes), .bytes(row[1].bytes)],
                [.text("HDEL"), k, .bytes(old.bytes)],
            ])
        case (.list, 1):
            guard let index = old.text, Int(index) != nil else {
                throw DatabaseError("Can’t locate this list element.")
            }
            try await run([.text("LSET"), k, .text(index), .bytes(newValue.bytes)])
        case (.set, 0):
            try await transaction([[.text("SREM"), k, .bytes(old.bytes)], [.text("SADD"), k, .bytes(newValue.bytes)]])
        case (.zset, 1):
            guard let score = newValue.text, Double(score) != nil else {
                throw DatabaseError("Score must be a number.")
            }
            try await run([.text("ZADD"), k, .text("XX"), .text(score), .bytes(old.bytes)])
        case (.zset, 0):
            try await transaction([
                [.text("ZREM"), k, .bytes(old.bytes)],
                [.text("ZADD"), k, .bytes(row[1].bytes), .bytes(newValue.bytes)],
            ])
        default:
            throw DatabaseError("This value can't be edited in place.")
        }
    }

    /// Removes elements identified by their first column (field, index, member or stream id).
    public func remove(_ key: RedisBytes, type: RedisKeyType, elements: [RedisBytes]) async throws {
        guard !elements.isEmpty else { return }
        let k = RedisArgument.bytes(key.bytes)
        let e = elements.map { RedisArgument.bytes($0.bytes) }
        switch type {
        case .hash: try await run([.text("HDEL"), k] + e)
        case .set: try await run([.text("SREM"), k] + e)
        case .zset: try await run([.text("ZREM"), k] + e)
        case .stream: try await run([.text("XDEL"), k] + e)
        case .list:
            // Lists have no delete-by-index: mark the slots with a unique tombstone, then remove it.
            let tombstone = RedisArgument.text("__tabula_deleted_\(UUID().uuidString)__")
            var commands: [[RedisArgument]] = elements.compactMap { $0.text.flatMap(Int.init) }
                .map { [.text("LSET"), k, .text(String($0)), tombstone] }
            commands.append([.text("LREM"), k, .text("0"), tombstone])
            try await transaction(commands)
        case .string, .unknown:
            break
        }
    }

    /// Runs commands in MULTI/EXEC; any error discards the whole block.
    func transaction(_ commands: [[RedisArgument]]) async throws {
        try await run([.text("MULTI")])
        do {
            for command in commands {
                let reply = try await send(command.map(\.bytes))
                if case .error(let message) = reply { throw DatabaseError(message) }
            }
        } catch {
            _ = try? await send(["DISCARD"].map { Array($0.utf8) })
            throw error
        }
        let results = try await run([.text("EXEC")])
        if results == .null { throw DatabaseError("The transaction was aborted; nothing was changed.") }
        if let failure = results.array.first(where: {
            if case .error = $0 { return true }
            return false
        }), case .error(let message) = failure {
            throw DatabaseError(message)
        }
    }
}

/// Carries a connection across the timeout helper's task boundary; it is only used by the actor afterwards.
private struct ConnectionBox: @unchecked Sendable {
    let connection: RedisConnection
}

/// An argument for a Redis command: text or raw bytes.
enum RedisArgument {
    case text(String)
    case bytes([UInt8])

    var bytes: [UInt8] {
        switch self {
        case .text(let text): Array(text.utf8)
        case .bytes(let bytes): bytes
        }
    }

    var text: String {
        switch self {
        case .text(let text): text
        case .bytes(let bytes): String(decoding: bytes, as: UTF8.self)
        }
    }

    var resp: RESPValue {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return .bulkString(buffer)
    }
}
