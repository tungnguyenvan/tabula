import Foundation
import TabulaDrivers
import TabulaFoundation

/// Parses and formats Redis commands the way `redis-cli` does.
public enum RedisCommandLine {
    /// Splits a console line into arguments. Supports "double quotes" with \n \r \t \" \\ \xHH escapes
    /// and 'single quotes' (only \' is special), like redis-cli.
    public static func parse(_ line: String) throws -> [[UInt8]] {
        var arguments: [[UInt8]] = []
        var current: [UInt8] = []
        var inArgument = false
        var scalars = Array(line.unicodeScalars)[...]

        func append(_ scalar: Unicode.Scalar) { current.append(contentsOf: Array(String(scalar).utf8)) }

        while let scalar = scalars.popFirst() {
            switch scalar {
            case " ", "\t", "\n", "\r":
                if inArgument {
                    arguments.append(current)
                    current = []
                    inArgument = false
                }
            case "\"":
                inArgument = true
                var closed = false
                while let next = scalars.popFirst() {
                    if next == "\"" {
                        closed = true
                        break
                    }
                    if next == "\\", let escaped = scalars.popFirst() {
                        switch escaped {
                        case "n": current.append(0x0A)
                        case "r": current.append(0x0D)
                        case "t": current.append(0x09)
                        case "b": current.append(0x08)
                        case "a": current.append(0x07)
                        case "x":
                            let hex = String(String.UnicodeScalarView(scalars.prefix(2)))
                            if hex.count == 2, let byte = UInt8(hex, radix: 16) {
                                current.append(byte)
                                scalars = scalars.dropFirst(2)
                            } else {
                                append("x")
                            }
                        default: append(escaped)
                        }
                    } else {
                        append(next)
                    }
                }
                guard closed else {
                    throw DatabaseError("Unbalanced double quotes")
                }
                if let next = scalars.first, next != " " && next != "\t" {
                    throw DatabaseError("Closing quote must be followed by a space")
                }
            case "'":
                inArgument = true
                var closed = false
                while let next = scalars.popFirst() {
                    if next == "'" {
                        closed = true
                        break
                    }
                    if next == "\\", scalars.first == "'" {
                        scalars = scalars.dropFirst()
                        append("'")
                        continue
                    }
                    append(next)
                }
                guard closed else {
                    throw DatabaseError("Unbalanced single quotes")
                }
                if let next = scalars.first, next != " " && next != "\t" {
                    throw DatabaseError("Closing quote must be followed by a space")
                }
            default:
                inArgument = true
                append(scalar)
            }
        }
        if inArgument {
            arguments.append(current)
        }
        return arguments
    }

    /// Quotes bytes for display: plain text as-is inside quotes, everything else escaped (redis-cli style).
    public static func quoted(_ bytes: [UInt8]) -> String {
        var text = "\""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case 0x5C: text += "\\\\"
            case 0x22: text += "\\\""
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            case 0x20...0x7E: text.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                // Keep valid multi-byte UTF-8 readable; escape anything else.
                if let (scalar, length) = decodeUTF8(bytes, at: index) {
                    text.unicodeScalars.append(scalar)
                    index += length
                    continue
                }
                text += String(format: "\\x%02x", byte)
            }
            index += 1
        }
        return text + "\""
    }

    private static func decodeUTF8(_ bytes: [UInt8], at index: Int) -> (Unicode.Scalar, Int)? {
        let first = bytes[index]
        let length: Int
        switch first {
        case 0xF0...:
            length = 4
        case 0xE0...:
            length = 3
        case 0xC2...:
            length = 2
        default:
            length = 0
        }
        guard length > 0, index + length <= bytes.count,
            let string = String(bytes: bytes[index..<index + length], encoding: .utf8),
            let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1
        else { return nil }
        return (scalar, length)
    }

    /// Commands the console refuses because they would block this connection indefinitely.
    public static func refusal(for arguments: [[UInt8]]) -> String? {
        guard let first = arguments.first, let name = String(bytes: first, encoding: .utf8)?.uppercased() else {
            return nil
        }
        switch name {
        case "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "SYNC", "PSYNC":
            return "\(name) would take over this connection and is not supported in the console. Use redis-cli for it."
        case "BLPOP", "BRPOP", "BLMOVE", "BRPOPLPUSH", "BZPOPMIN", "BZPOPMAX", "BLMPOP", "BZMPOP", "XREAD",
            "XREADGROUP", "WAIT", "WAITAOF":
            // A zero timeout blocks forever.
            if let timeoutIndex = blockingTimeoutIndex(name, arguments),
                timeoutIndex < arguments.count,
                let timeout = Double(String(decoding: arguments[timeoutIndex], as: UTF8.self)), timeout == 0
            {
                return "\(name) with timeout 0 would block forever. Give it a timeout in seconds."
            }
            return nil
        default:
            return nil
        }
    }

    private static func blockingTimeoutIndex(_ name: String, _ arguments: [[UInt8]]) -> Int? {
        switch name {
        case "BLPOP", "BRPOP", "BZPOPMIN", "BZPOPMAX": return arguments.count - 1
        case "BRPOPLPUSH": return 3
        case "BLMOVE": return 5
        case "BLMPOP", "BZMPOP": return 1
        case "WAIT": return 2
        case "WAITAOF": return 3
        case "XREAD", "XREADGROUP":
            let upper = arguments.map { String(decoding: $0, as: UTF8.self).uppercased() }
            return upper.firstIndex(of: "BLOCK").map { $0 + 1 }
        default: return nil
        }
    }

    /// Commands known to only read. On production connections everything else asks first, so a command
    /// missing here costs a confirmation rather than an unconfirmed write.
    private static let readOnlyCommands: Set<String> = [
        "GET", "MGET", "GETRANGE", "STRLEN", "EXISTS", "TYPE", "TTL", "PTTL", "EXPIRETIME", "PEXPIRETIME", "KEYS",
        "SCAN", "RANDOMKEY",
        "DBSIZE", "HGET", "HMGET", "HGETALL", "HKEYS", "HVALS", "HLEN", "HEXISTS", "HSTRLEN", "HSCAN", "HRANDFIELD",
        "LRANGE", "LINDEX", "LLEN", "LPOS", "SMEMBERS", "SISMEMBER", "SMISMEMBER", "SCARD", "SSCAN", "SRANDMEMBER",
        "SINTER", "SUNION",
        "SDIFF", "SINTERCARD", "ZRANGE", "ZRANGEBYSCORE", "ZRANGEBYLEX", "ZREVRANGE", "ZREVRANGEBYSCORE",
        "ZREVRANGEBYLEX", "ZSCORE",
        "ZMSCORE", "ZRANK", "ZREVRANK", "ZCARD", "ZCOUNT", "ZLEXCOUNT", "ZSCAN", "ZRANDMEMBER", "XRANGE", "XREVRANGE",
        "XLEN", "XINFO",
        "XPENDING", "XREAD", "PFCOUNT", "GETBIT", "BITCOUNT", "BITPOS", "GEOPOS", "GEODIST", "GEOHASH", "GEOSEARCH",
        "OBJECT", "MEMORY",
        "DUMP", "INFO", "PING", "ECHO", "TIME", "SELECT", "CLIENT", "CONFIG", "COMMAND", "SLOWLOG", "LATENCY",
        "LASTSAVE", "ROLE",
        "HELLO", "AUTH", "SUBSCRIBE", "PSUBSCRIBE", "PUBSUB", "MONITOR",
    ]

    public static func isReadOnly(_ arguments: [[UInt8]]) -> Bool {
        guard let name = arguments.first.map({ String(decoding: $0, as: UTF8.self).uppercased() }) else { return true }
        if name == "CONFIG" || name == "CLIENT" || name == "OBJECT" || name == "MEMORY" {
            // Only their inspection subcommands.
            let sub = arguments.count > 1 ? String(decoding: arguments[1], as: UTF8.self).uppercased() : ""
            return [
                "GET", "LIST", "INFO", "ENCODING", "FREQ", "IDLETIME", "REFCOUNT", "USAGE", "STATS", "GETNAME", "ID",
                "HELP",
            ]
            .contains(sub)
        }
        return readOnlyCommands.contains(name)
    }

    /// Commands that need an explicit confirmation in the console.
    public static func isDestructive(_ arguments: [[UInt8]]) -> Bool {
        guard let first = arguments.first, let name = String(bytes: first, encoding: .utf8)?.uppercased() else {
            return false
        }
        return ["FLUSHALL", "FLUSHDB", "SHUTDOWN", "SWAPDB"].contains(name)
            || (name == "CONFIG" && arguments.count > 1
                && String(decoding: arguments[1], as: UTF8.self).uppercased() == "SET")
    }
}

/// A RESP reply, independent of the client library.
public indirect enum RedisReply: Equatable, Sendable {
    case status(String)
    case error(String)
    case integer(Int)
    case bulk([UInt8])
    case null
    case array([RedisReply])

    /// Text as redis-cli prints it.
    public func formatted(indent: Int = 0) -> String {
        switch self {
        case .status(let text): return text
        case .error(let text): return "(error) " + text
        case .integer(let value): return "(integer) \(value)"
        case .bulk(let bytes): return RedisCommandLine.quoted(bytes)
        case .null: return "(nil)"
        case .array(let items):
            if items.isEmpty {
                return "(empty array)"
            }
            let width = String(items.count).count
            return items.enumerated()
                .map { index, item in
                    let number = String(repeating: " ", count: width - String(index + 1).count) + "\(index + 1)) "
                    let prefix = index == 0 ? "" : String(repeating: " ", count: indent)
                    return prefix + number + item.formatted(indent: indent + number.count)
                }
                .joined(separator: "\n")
        }
    }

    public var string: String? {
        switch self {
        case .status(let text): text
        case .bulk(let bytes): String(decoding: bytes, as: UTF8.self)
        case .integer(let value): String(value)
        default: nil
        }
    }

    public var bytes: [UInt8]? {
        if case .bulk(let bytes) = self {
            return bytes
        }
        if case .status(let text) = self {
            return Array(text.utf8)
        }
        return nil
    }

    public var int: Int? {
        switch self {
        case .integer(let value): value
        case .bulk, .status: string.flatMap { Int($0) }
        default: nil
        }
    }

    public var array: [RedisReply] {
        if case .array(let items) = self {
            return items
        }
        return []
    }
}

public enum RedisTTL {
    /// Parses an expiry typed by the user: "3600", "90s", "1h 30m", "2d"; empty, "none", "-" or "no expiry" removes it (nil).
    public static func parse(_ text: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["", "none", "-", "∞", "no expiry", "persist", "never"].contains(trimmed) { return nil }
        if let seconds = Int(trimmed) {
            guard seconds > 0 else {
                throw DatabaseError("TTL must be at least 1 second.")
            }
            return seconds
        }
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600, "d": 86_400, "w": 604_800]
        var total = 0
        var number = ""
        var sawUnit = false
        for character in trimmed where !character.isWhitespace {
            if character.isNumber {
                number.append(character)
            } else if let unit = units[character], let value = Int(number) {
                total += value * unit
                number = ""
                sawUnit = true
            } else {
                throw DatabaseError("Use seconds or a duration like 90s, 30m, 1h 30m or 2d; leave empty for no expiry.")
            }
        }
        guard number.isEmpty, sawUnit, total > 0 else {
            throw DatabaseError("Use seconds or a duration like 90s, 30m, 1h 30m or 2d; leave empty for no expiry.")
        }
        return total
    }

    /// "1h 2m" style, matching what `parse` accepts; nil means no expiry.
    public static func format(milliseconds: Int?) -> String {
        guard let milliseconds else { return "" }
        var seconds = max(1, milliseconds / 1000)
        let days = seconds / 86_400
        seconds %= 86_400
        let hours = seconds / 3600
        seconds %= 3600
        let minutes = seconds / 60
        seconds %= 60
        return [(days, "d"), (hours, "h"), (minutes, "m"), (seconds, "s")].filter { $0.0 > 0 }.prefix(2)
            .map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }
}
