import BSON
import Foundation
import NIOCore
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// BSON values as MongoDB shell text, and back.
///
/// Tabula shows documents the way mongosh does (`ObjectId("…")`, `ISODate("…")`, `NumberLong(…)`) and
/// reads that text back, along with Extended JSON (`{"$oid": "…"}`) and plain JSON, so a value keeps its
/// type through an edit.
public enum MongoShell {
    public struct ParseError: LocalizedError, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    // MARK: Writing

    /// `value` as shell text; `pretty` puts each field of a document on its own indented line, keeping short
    /// nested values on one.
    public static func format(_ value: Primitive, pretty: Bool = false) -> String {
        var output = ""
        write(value, into: &output, indent: pretty ? 0 : nil)
        return output
    }

    /// Text for a grid cell: strings, numbers, ids and dates as plain text, everything else as `format` writes it.
    /// Edits read the text back in the type the field already had (see `MongoChanges`).
    public static func cell(_ value: Primitive) -> String? {
        switch ValueKind(value) {
        case .string: return (value as! String)
        case .null: return nil
        case .int32: return String(value as! Int32)
        case .int64: return String(value as! Int)
        case .double:
            let double = value as! Double
            if double.isFinite, double == double.rounded(), let int = Int64(exactly: double), abs(int) < 1 << 53 {
                return String(int)
            }
            return number(double)
        case .objectId: return (value as! ObjectId).hexString
        case .decimal: return MongoDecimal.string(value as! Decimal128)
        case .date:
            let date = value as! Date
            return isoText(date) ?? format(date)
        case .bool: return (value as! Bool) ? "true" : "false"
        default: return format(value)
        }
    }

    /// Shell text re-written over indented lines, for editing a whole document; unchanged if it doesn't parse.
    public static func pretty(_ text: String) -> String {
        (try? parseValue(text)).map { format($0, pretty: true) } ?? text
    }

    /// A field name as the shell writes it: bare when it is an identifier, quoted otherwise.
    public static func key(_ name: String) -> String {
        isIdentifier(name) ? name : quoted(name)
    }

    public static func quoted(_ string: String) -> String {
        // Most strings need no escapes; skip the per-character walk for them.
        if !string.utf8.contains(where: { $0 < 0x20 || $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") }) {
            return "\"" + string + "\""
        }
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.utf8.first, MongoShellParser.isIdentifierStart(first) else { return false }
        return name.utf8.allSatisfy(MongoShellParser.isIdentifierPart)
    }

    private static func write(_ value: Primitive, into output: inout String, indent: Int?) {
        // One type lookup, then a single cast: trying `as` for each type in turn was most of the cost of a page.
        switch ValueKind(value) {
        case .document: writeDocument(value as! Document, into: &output, indent: indent)
        case .string: output += quoted(value as! String)
        case .int32: output += String(value as! Int32)
        case .int64: output += "NumberLong(\(value as! Int))"
        case .double: output += number(value as! Double)
        case .bool: output += (value as! Bool) ? "true" : "false"
        case .null: output += "null"
        case .objectId: output += "ObjectId(\"\((value as! ObjectId).hexString)\")"
        case .date: output += dateText(value as! Date)
        case .binary: output += binaryText(value as! Binary)
        case .regex:
            let regex = value as! RegularExpression
            output += "/" + regex.pattern.replacingOccurrences(of: "/", with: "\\/") + "/" + regex.options
        case .timestamp:
            let timestamp = value as! Timestamp
            output +=
                "Timestamp({ t: \(UInt32(bitPattern: timestamp.timestamp)), i: \(UInt32(bitPattern: timestamp.increment)) })"
        case .decimal: output += "NumberDecimal(\"\(MongoDecimal.string(value as! Decimal128))\")"
        case .minKey: output += "MinKey()"
        case .maxKey: output += "MaxKey()"
        case .code: output += "Code(\(quoted((value as! JavaScriptCode).code)))"
        case .codeWithScope:
            let code = value as! JavaScriptCodeWithScope
            output += "Code(\(quoted(code.code)), \(format(code.scope)))"
        case .other: output += quoted(String(describing: value))
        }
    }

    private static func writeDocument(_ document: Document, into output: inout String, indent: Int?) {
        let open = document.isArray ? "[" : "{"
        let close = document.isArray ? "]" : "}"
        guard !document.isEmpty else {
            output += open + close
            return
        }
        let items: [(key: String?, value: Primitive)] =
            document.isArray
            ? document.values.map { (nil, $0) } : document.pairs.map { ($0.key, $0.value) }
        // Short nested values read best on one line, even when pretty.
        let inline = indent == nil || (indent != 0 && format(document).count <= Defaults.Mongo.inlineWidth)
        if inline {
            output += document.isArray ? "[" : "{ "
            for (index, item) in items.enumerated() {
                if index > 0 {
                    output += ", "
                }
                if let key = item.key {
                    output += key.isEmpty ? "\"\": " : self.key(key) + ": "
                }
                write(item.value, into: &output, indent: nil)
            }
            output += document.isArray ? "]" : " }"
            return
        }
        let level = indent ?? 0
        let inner = String(repeating: " ", count: (level + 1) * Defaults.Mongo.indentWidth)
        output += open + "\n"
        for (index, item) in items.enumerated() {
            output += inner
            if let key = item.key {
                output += (key.isEmpty ? "\"\"" : self.key(key)) + ": "
            }
            write(item.value, into: &output, indent: level + 1)
            output += index < items.count - 1 ? ",\n" : "\n"
        }
        output += String(repeating: " ", count: level * Defaults.Mongo.indentWidth) + close
    }

    /// Doubles always show a decimal point or exponent, so they read back as doubles, not integers.
    static func number(_ double: Double) -> String {
        if double.isNaN {
            return "NaN"
        }
        if double.isInfinite {
            return double < 0 ? "-Infinity" : "Infinity"
        }
        let text = "\(double)"
        return text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) ? text : text + ".0"
    }

    static func dateText(_ date: Date) -> String {
        isoText(date).map { "ISODate(\"\($0)\")" }
            ?? "new Date(\(Int64((date.timeIntervalSince1970 * 1000).rounded())))"
    }

    /// ISO 8601 with milliseconds, for years ISO can write (1–9999).
    static func isoText(_ date: Date) -> String? {
        // BSON dates are whole milliseconds; work from that integer so .678 doesn't print as .677.
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        guard let exact = Int64(exactly: milliseconds) else { return nil }
        return CivilTime.isoText(milliseconds: exact)
    }

    private static func binaryText(_ binary: Binary) -> String {
        let data = binary.data
        if case .uuid = binary.subType, data.count == 16 {
            let hex = data.map { String(format: "%02x", $0) }.joined()
            let parts = [
                hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4),
                hex.dropFirst(20),
            ]
            return "UUID(\"\(parts.joined(separator: "-"))\")"
        }
        return "BinData(\(subtypeByte(binary.subType)), \"\(data.base64EncodedString())\")"
    }

    static func subtypeByte(_ subtype: Binary.SubType) -> UInt8 {
        switch subtype {
        case .generic: 0
        case .function: 1
        case .uuid: 4
        case .md5: 5
        case .userDefined(let byte): byte
        }
    }

    static func subtype(_ byte: UInt8) -> Binary.SubType {
        switch byte {
        case 0: .generic
        case 1: .function
        case 4: .uuid
        case 5: .md5
        default: .userDefined(byte)
        }
    }

    /// BSON type name, as `$type` and Compass spell it.
    public static func typeName(_ value: Primitive) -> String {
        switch ValueKind(value) {
        case .document: (value as! Document).isArray ? "array" : "object"
        case .string: "string"
        case .int32: "int"
        case .int64: "long"
        case .double: "double"
        case .bool: "bool"
        case .null: "null"
        case .objectId: "objectId"
        case .date: "date"
        case .binary: "binData"
        case .regex: "regex"
        case .timestamp: "timestamp"
        case .decimal: "decimal"
        case .minKey: "minKey"
        case .maxKey: "maxKey"
        case .code, .codeWithScope: "javascript"
        case .other: "unknown"
        }
    }

    // MARK: Reading

    /// One value, e.g. `{ name: "Ann", born: ISODate("1990-01-01") }`, `42` or `"text"`.
    public static func parseValue(_ text: String) throws -> Primitive {
        var parser = MongoShellParser(text)
        let value = try parser.value()
        try parser.expectEnd()
        return value
    }

    /// A document (not an array); empty text is the empty document.
    public static func parseDocument(_ text: String) throws -> Document {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Document()
        }
        guard let document = try parseValue(text) as? Document, !document.isArray else {
            throw ParseError("Expected a document like { field: value }.")
        }
        return document
    }
}

/// The BSON type of a value, found with one dictionary lookup of its dynamic type.
enum ValueKind {
    case document, string, int32, int64, double, bool, null, objectId, date, binary, regex, timestamp, decimal
    case minKey, maxKey, code, codeWithScope, other

    private static let kinds: [ObjectIdentifier: ValueKind] = [
        ObjectIdentifier(Document.self): .document, ObjectIdentifier(String.self): .string,
        ObjectIdentifier(Int32.self): .int32,
        ObjectIdentifier(Int.self): .int64, ObjectIdentifier(Double.self): .double, ObjectIdentifier(Bool.self): .bool,
        ObjectIdentifier(Null.self): .null, ObjectIdentifier(ObjectId.self): .objectId,
        ObjectIdentifier(Date.self): .date,
        ObjectIdentifier(Binary.self): .binary, ObjectIdentifier(RegularExpression.self): .regex,
        ObjectIdentifier(Timestamp.self): .timestamp, ObjectIdentifier(Decimal128.self): .decimal,
        ObjectIdentifier(MinKey.self): .minKey, ObjectIdentifier(MaxKey.self): .maxKey,
        ObjectIdentifier(JavaScriptCode.self): .code, ObjectIdentifier(JavaScriptCodeWithScope.self): .codeWithScope,
    ]

    init(_ value: Primitive) {
        self = Self.kinds[ObjectIdentifier(type(of: value))] ?? .other
    }
}

/// Reads shell text: JSON plus unquoted keys, single quotes, comments, trailing commas, regex literals and
/// the shell's constructors (ObjectId, ISODate, NumberLong, NumberDecimal, UUID, BinData, Timestamp…).
struct MongoShellParser {
    private let bytes: [UInt8]
    private(set) var index = 0
    /// Set when a comment was skipped (the beautifier leaves such text alone, since comments would be lost).
    private(set) var sawComment = false
    /// Set when a value was made at parse time (`ObjectId()`, `new Date()`, `UUID()`); re-printing would freeze it.
    private(set) var madeValue = false

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    var isAtEnd: Bool { index >= bytes.count }

    func peek(_ offset: Int = 0) -> UInt8? {
        index + offset < bytes.count ? bytes[index + offset] : nil
    }

    mutating func skipSpace() {
        while let byte = peek() {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            } else if byte == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "/") {
                sawComment = true
                while let next = peek(), next != 0x0A {
                    index += 1
                }
            } else if byte == UInt8(ascii: "/"), peek(1) == UInt8(ascii: "*") {
                sawComment = true
                index += 2
                while !isAtEnd, !(peek() == UInt8(ascii: "*") && peek(1) == UInt8(ascii: "/")) { index += 1 }
                index = min(bytes.count, index + 2)
            } else {
                return
            }
        }
    }

    mutating func expectEnd() throws {
        skipSpace()
        if peek() == UInt8(ascii: ";") {
            index += 1
            skipSpace()
        }
        guard isAtEnd else {
            throw error("Unexpected text")
        }
    }

    /// Consumes `byte` (after optional space) when it is next.
    mutating func take(_ character: Character) -> Bool {
        skipSpace()
        guard let ascii = character.asciiValue, peek() == ascii else { return false }
        index += 1
        return true
    }

    mutating func expect(_ character: Character) throws {
        guard take(character) else {
            throw error("Expected “\(character)”")
        }
    }

    func error(_ message: String) -> MongoShell.ParseError {
        // Report a 1-based line and column, like an editor would show.
        let before = bytes[0..<min(index, bytes.count)]
        let line = before.filter { $0 == 0x0A }.count + 1
        let column = before.count - (before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0) + 1
        let near = String(decoding: bytes[min(index, bytes.count)..<min(index + 20, bytes.count)], as: UTF8.self)
        let tail = near.isEmpty ? " at the end" : " near “\(near.prefix(while: { $0 != "\n" }))”"
        return MongoShell.ParseError("\(message) (line \(line), column \(column))\(tail).")
    }

    static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "$")
    }

    static func isIdentifierPart(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39)
    }

    mutating func identifier() -> String? {
        skipSpace()
        guard let first = peek(), Self.isIdentifierStart(first) else { return nil }
        let start = index
        while let byte = peek(), Self.isIdentifierPart(byte) {
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    // MARK: Values

    mutating func value() throws -> Primitive {
        skipSpace()
        guard let byte = peek() else {
            throw error("Expected a value")
        }
        switch byte {
        case UInt8(ascii: "{"):
            return try MongoExtendedJSON.convert(object())
        case UInt8(ascii: "["):
            return try array()
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            return try string()
        case UInt8(ascii: "/"):
            return try regex()
        case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try number()
        default:
            guard Self.isIdentifierStart(byte) else {
                throw error("Expected a value")
            }
            return try word()
        }
    }

    private mutating func object() throws -> Document {
        try expect("{")
        var document = Document()
        while !take("}") {
            skipSpace()
            let key: String
            if peek() == UInt8(ascii: "\"") || peek() == UInt8(ascii: "'") {
                key = try string()
            } else if let name = identifier() {
                key = name
            } else if let byte = peek(), byte >= 0x30 && byte <= 0x39 {
                let start = index
                while let digit = peek(), digit >= 0x30 && digit <= 0x39 {
                    index += 1
                }
                key = String(decoding: bytes[start..<index], as: UTF8.self)
            } else {
                throw error("Expected a field name")
            }
            try expect(":")
            document.appendValue(try value(), forKey: key)
            if !take(",") {
                try expect("}")
                break
            }
        }
        return document
    }

    private mutating func array() throws -> Document {
        try expect("[")
        var document = Document(isArray: true)
        while !take("]") {
            document.append(try value())
            if !take(",") {
                try expect("]")
                break
            }
        }
        return document
    }

    mutating func string() throws -> String {
        skipSpace()
        guard let quote = peek(), quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
            throw error("Expected a string")
        }
        index += 1
        var output: [UInt8] = []
        while true {
            guard let byte = peek() else {
                throw error("Unterminated string")
            }
            index += 1
            if byte == quote {
                break
            }
            if byte == 0x0A {
                throw error("Unterminated string")
            }
            guard byte == UInt8(ascii: "\\") else {
                output.append(byte)
                continue
            }
            guard let escaped = peek() else {
                throw error("Unterminated string")
            }
            index += 1
            switch escaped {
            case UInt8(ascii: "n"): output.append(0x0A)
            case UInt8(ascii: "t"): output.append(0x09)
            case UInt8(ascii: "r"): output.append(0x0D)
            case UInt8(ascii: "b"): output.append(0x08)
            case UInt8(ascii: "f"): output.append(0x0C)
            case UInt8(ascii: "v"): output.append(0x0B)
            case UInt8(ascii: "0"): output.append(0x00)
            case 0x0A: break  // line continuation
            case UInt8(ascii: "x"):
                output.append(contentsOf: Self.utf8(try hexValue(digits: 2)))
            case UInt8(ascii: "u"):
                var value = try hexValue(digits: 4)
                // A surrogate pair spells one character outside the basic plane.
                if (0xD800...0xDBFF).contains(value), peek() == UInt8(ascii: "\\"), peek(1) == UInt8(ascii: "u") {
                    index += 2
                    let low = try hexValue(digits: 4)
                    value =
                        (0xDC00...0xDFFF).contains(low) ? 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00) : 0xFFFD
                }
                output.append(contentsOf: Self.utf8(value))
            default:
                output.append(escaped)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private mutating func hexValue(digits count: Int) throws -> UInt32 {
        guard index + count <= bytes.count,
            let value = UInt32(String(decoding: bytes[index..<index + count], as: UTF8.self), radix: 16)
        else {
            throw error("Invalid escape")
        }
        index += count
        return value
    }

    /// UTF-8 for a code point; an unpaired surrogate becomes U+FFFD.
    private static func utf8(_ value: UInt32) -> [UInt8] {
        Array(String(Unicode.Scalar(value) ?? "\u{FFFD}").utf8)
    }

    private mutating func number() throws -> Primitive {
        skipSpace()
        let start = index
        if peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+") { index += 1 }
        if let name = identifier() {
            let negative = bytes[start] == UInt8(ascii: "-")
            switch name {
            case "Infinity": return negative ? -Double.infinity : Double.infinity
            case "NaN": return Double.nan
            default: throw error("Expected a number")
            }
        }
        var isInteger = true
        while let byte = peek() {
            if byte >= 0x30 && byte <= 0x39 {
                index += 1
            } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E"),
                    peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+")
                {
                    index += 1
                }
            } else {
                break
            }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        // Integers become int32 when they fit and int64 otherwise, as the shell stores them.
        if isInteger, let int = Int(text.hasPrefix("+") ? String(text.dropFirst()) : text) {
            return Int32(exactly: int).map { $0 as Primitive } ?? int
        }
        guard let double = Double(text) else {
            throw error("Invalid number")
        }
        return double
    }

    private mutating func regex() throws -> Primitive {
        try expect("/")
        var pattern: [UInt8] = []
        var inClass = false
        while true {
            guard let byte = peek(), byte != 0x0A else {
                throw error("Unterminated regular expression")
            }
            index += 1
            if byte == UInt8(ascii: "\\"), let next = peek() {
                index += 1
                // `\/` only escapes the delimiter; the pattern itself keeps a plain slash.
                if next != UInt8(ascii: "/") { pattern.append(byte) }
                pattern.append(next)
                continue
            }
            if byte == UInt8(ascii: "[") { inClass = true }
            if byte == UInt8(ascii: "]") { inClass = false }
            if byte == UInt8(ascii: "/") && !inClass { break }
            pattern.append(byte)
        }
        let start = index
        while let byte = peek(), byte >= 0x61 && byte <= 0x7A {
            index += 1
        }
        let options = String(decoding: bytes[start..<index], as: UTF8.self)
        return RegularExpression(pattern: String(decoding: pattern, as: UTF8.self), options: String(options.sorted()))
    }

    /// Keywords and constructors: true, null, ObjectId("…"), new Date(…), NumberLong(…), …
    private mutating func word() throws -> Primitive {
        let wordStart = index
        guard var name = identifier() else {
            throw error("Expected a value")
        }
        if name == "new", let constructor = identifier() { name = constructor }
        // Qualified constructors: Binary.createFromBase64, Decimal128.fromString, …
        while peek() == UInt8(ascii: "."), let next = peek(1), Self.isIdentifierStart(next) {
            index += 1
            name += "." + (identifier() ?? "")
        }
        switch name {
        case "true": return true
        case "false": return false
        case "null", "undefined": return Null()
        case "Infinity": return Double.infinity
        case "NaN": return Double.nan
        case "MinKey":
            _ = try optionalArguments()
            return MinKey()
        case "MaxKey":
            _ = try optionalArguments()
            return MaxKey()
        default: break
        }
        guard let arguments = try optionalArguments() else {
            index = wordStart
            throw error("Unknown value “\(name)”")
        }
        func argument(_ position: Int) -> Primitive? {
            arguments.indices.contains(position) ? arguments[position] : nil
        }
        func text(_ position: Int) throws -> String {
            if let string = argument(position) as? String {
                return string
            }
            if let number = argument(position) {
                return MongoShell.format(number)
            }
            throw error("\(name) needs an argument")
        }

        switch name {
        case "ObjectId", "ObjectID":
            guard let hex = argument(0) as? String else {
                madeValue = true
                return ObjectId()
            }
            guard let id = ObjectId(hex) else {
                throw error("“\(hex)” isn't a valid ObjectId (24 hex digits)")
            }
            return id
        case "ISODate", "Date":
            switch argument(0) {
            case nil:
                madeValue = true
                return Date()
            case let string as String:
                guard let date = MongoDates.parse(string) else {
                    throw error("“\(string)” isn't a date")
                }
                return date
            case let value?:
                guard let milliseconds = Self.double(value) else {
                    throw error("Date needs a string or milliseconds")
                }
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
        case "NumberLong", "Long", "Long.fromString", "Long.fromNumber":
            if let int = argument(0) as? Int {
                return int
            }
            if let int = argument(0) as? Int32 {
                return Int(int)
            }
            let value = try text(0)
            guard let int = Int(value) ?? Self.double(argument(0) ?? Null()).flatMap({ Int(exactly: $0) }) else {
                throw error("“\(value)” isn't a 64-bit integer")
            }
            return int
        case "NumberInt", "Int32":
            if let int = argument(0) as? Int32 {
                return int
            }
            let value = try text(0)
            guard let int = Int32(value) ?? Self.double(argument(0) ?? Null()).flatMap({ Int32(exactly: $0) }) else {
                throw error("“\(value)” isn't a 32-bit integer")
            }
            return int
        case "Double":
            guard let double = Self.double(argument(0) ?? Null()) ?? (try? text(0)).flatMap(Double.init) else {
                throw error("Double needs a number")
            }
            return double
        case "NumberDecimal", "Decimal128", "Decimal128.fromString":
            let value = try text(0)
            guard let decimal = MongoDecimal.parse(value) else {
                throw error("“\(value)” isn't a decimal number")
            }
            return decimal
        case "UUID":
            guard let string = argument(0) as? String else {
                madeValue = true
                return MongoBinary.uuid(UUID())
            }
            guard let binary = MongoBinary.uuid(string) else {
                throw error("“\(string)” isn't a UUID")
            }
            return binary
        case "BinData":
            guard let sub = argument(0).flatMap(Self.double), let base64 = argument(1) as? String,
                let data = Data(base64Encoded: base64)
            else {
                throw error("BinData needs a subtype and base64 text")
            }
            return MongoBinary.make(data, subtype: UInt8(clamping: Int(sub)))
        case "Binary.createFromBase64":
            guard let base64 = argument(0) as? String, let data = Data(base64Encoded: base64) else {
                throw error("Expected base64 text")
            }
            return MongoBinary.make(data, subtype: UInt8(clamping: Int(argument(1).flatMap(Self.double) ?? 0)))
        case "HexData", "Binary.createFromHexString":
            let hexPosition = name == "HexData" ? 1 : 0
            guard let hex = argument(hexPosition) as? String, let data = MongoBinary.data(hex: hex) else {
                throw error("Expected hex text")
            }
            let sub = argument(name == "HexData" ? 0 : 1).flatMap(Self.double) ?? 0
            return MongoBinary.make(data, subtype: UInt8(clamping: Int(sub)))
        case "Timestamp":
            if let document = argument(0) as? Document {
                return Self.timestamp(t: document["t"], i: document["i"])
            }
            return Self.timestamp(t: argument(0), i: argument(1))
        case "RegExp":
            let pattern = try text(0)
            return RegularExpression(pattern: pattern, options: String(((argument(1) as? String) ?? "").sorted()))
        case "Code":
            let code = try text(0)
            if let scope = argument(1) as? Document {
                return JavaScriptCodeWithScope(code, scope: scope)
            }
            return JavaScriptCode(code)
        default:
            index = wordStart
            throw error("Unknown value “\(name)”")
        }
    }

    /// `( value, value… )` after a constructor name; nil when no parenthesis follows.
    mutating func optionalArguments() throws -> [Primitive]? {
        let saved = index
        guard take("(") else {
            index = saved
            return nil
        }
        var arguments: [Primitive] = []
        while !take(")") {
            arguments.append(try value())
            if !take(",") {
                try expect(")")
                break
            }
        }
        return arguments
    }

    static func double(_ value: Primitive) -> Double? {
        switch value {
        case let int as Int32: Double(int)
        case let int as Int: Double(int)
        case let double as Double: double
        case let string as String: Double(string)
        default: nil
        }
    }

    static func timestamp(t: Primitive?, i: Primitive?) -> Timestamp {
        let seconds = t.flatMap(double).map { UInt32(clamping: Int64($0)) } ?? 0
        let increment = i.flatMap(double).map { UInt32(clamping: Int64($0)) } ?? 0
        return Timestamp(increment: Int32(bitPattern: increment), timestamp: Int32(bitPattern: seconds))
    }
}

/// Extended JSON wrappers (`{"$oid": …}`, `{"$date": …}`, …) turned into the values they stand for.
enum MongoExtendedJSON {
    static func convert(_ document: Document) throws -> Primitive {
        let keys = document.keys
        guard let first = keys.first, first.hasPrefix("$") else {
            return document
        }
        if keys.count == 2, Set(keys) == ["$binary", "$type"], let base64 = document["$binary"] as? String,
            let type = document["$type"] as? String, let data = Data(base64Encoded: base64),
            let sub = UInt8(type, radix: 16)
        {
            return MongoBinary.make(data, subtype: sub)
        }
        guard keys.count == 1, let value = document[first] else {
            return document
        }
        func fail() -> MongoShell.ParseError { MongoShell.ParseError("Invalid Extended JSON value for \(first).") }
        switch first {
        case "$oid":
            guard let hex = value as? String, let id = ObjectId(hex) else {
                throw fail()
            }
            return id
        case "$date":
            switch value {
            case let string as String:
                guard let date = MongoDates.parse(string) else {
                    throw fail()
                }
                return date
            case let wrapped as Document:
                guard let text = wrapped["$numberLong"] as? String, let milliseconds = Int64(text) else {
                    throw fail()
                }
                return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            default:
                guard let milliseconds = MongoShellParser.double(value) else {
                    throw fail()
                }
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
        case "$numberLong":
            guard let text = value as? String, let int = Int(text) else {
                throw fail()
            }
            return int
        case "$numberInt":
            guard let text = value as? String, let int = Int32(text) else {
                throw fail()
            }
            return int
        case "$numberDouble":
            guard let text = value as? String else {
                throw fail()
            }
            switch text {
            case "Infinity": return Double.infinity
            case "-Infinity": return -Double.infinity
            case "NaN": return Double.nan
            default:
                guard let double = Double(text) else {
                    throw fail()
                }
                return double
            }
        case "$numberDecimal":
            guard let text = value as? String, let decimal = MongoDecimal.parse(text) else {
                throw fail()
            }
            return decimal
        case "$binary":
            guard let wrapped = value as? Document, let base64 = wrapped["base64"] as? String,
                let data = Data(base64Encoded: base64)
            else {
                throw fail()
            }
            return MongoBinary.make(
                data,
                subtype: (wrapped["subType"] as? String).flatMap { UInt8($0, radix: 16) } ?? 0
            )
        case "$uuid":
            guard let text = value as? String, let binary = MongoBinary.uuid(text) else {
                throw fail()
            }
            return binary
        case "$regularExpression":
            guard let wrapped = value as? Document, let pattern = wrapped["pattern"] as? String else {
                throw fail()
            }
            return RegularExpression(
                pattern: pattern,
                options: String(((wrapped["options"] as? String) ?? "").sorted())
            )
        case "$timestamp":
            guard let wrapped = value as? Document else {
                throw fail()
            }
            return MongoShellParser.timestamp(t: wrapped["t"], i: wrapped["i"])
        case "$minKey": return MinKey()
        case "$maxKey": return MaxKey()
        case "$symbol":
            guard let text = value as? String else {
                throw fail()
            }
            return text
        case "$code":
            guard let text = value as? String else {
                throw fail()
            }
            return JavaScriptCode(text)
        default:
            // An operator such as {$gt: 5}: a document, not a wrapped value.
            return document
        }
    }
}

enum MongoDates {
    /// ISO 8601 dates as the shell accepts them: with or without time, fraction and zone (no zone means UTC).
    static func parse(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let milliseconds = CivilTime.milliseconds(iso: text) {
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let variants: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate, .withFractionalSeconds],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate],
            [.withFullDate, .withDashSeparatorInDate],
        ]
        // "2024-01-02 10:00:00" is common too.
        let candidates = [text, text.replacingOccurrences(of: " ", with: "T")]
        for candidate in candidates {
            for options in variants {
                formatter.formatOptions = options
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
        }
        return nil
    }
}

enum MongoBinary {
    static func make(_ data: Data, subtype: UInt8) -> Binary {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Binary(subType: MongoShell.subtype(subtype), buffer: buffer)
    }

    static func uuid(_ uuid: UUID) -> Binary {
        make(withUnsafeBytes(of: uuid.uuid) { Data($0) }, subtype: 4)
    }

    static func uuid(_ text: String) -> Binary? {
        guard let data = data(hex: text.replacingOccurrences(of: "-", with: "")), data.count == 16 else { return nil }
        return make(data, subtype: 4)
    }

    static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

extension DocumentTexts {
    /// Documents written as shell text when a row's text is asked for.
    init(_ values: [Primitive]) {
        self.init(count: values.count) { MongoShell.format(values[$0]) }
    }
}
