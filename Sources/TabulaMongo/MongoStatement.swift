import BSON
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// One statement in the MongoDB shell's syntax: `db.users.find({ age: { $gt: 30 } }).sort({ name: 1 })`,
/// `db.runCommand({ ping: 1 })`, `show collections`, `use shop`.
///
/// Tabula doesn't run JavaScript; it reads the method calls and their arguments and sends the matching
/// database commands.
public struct MongoStatement: Sendable {
    public enum Target: Sendable, Equatable {
        case show(String)
        case use(String)
        case database
        case collection(String)
    }

    public struct Call: Sendable {
        public var name: String
        public var arguments: [Primitive]

        public init(_ name: String, _ arguments: [Primitive] = []) {
            self.name = name
            self.arguments = arguments
        }
    }

    public var target: Target
    /// From `db.getSiblingDB("other")`; nil is the current database.
    public var database: String?
    /// The method called on the target, then any cursor methods chained after it (sort, limit, …).
    public var calls: [Call]
    /// The text had comments, which `formatted()` would drop.
    public var hasComments = false
    /// The text makes values when it runs (`ObjectId()`, `new Date()`), which `formatted()` would write as constants.
    public var makesValues = false

    public init(target: Target, database: String? = nil, calls: [Call] = []) {
        self.target = target
        self.database = database
        self.calls = calls
    }

    public var method: String? { calls.first?.name }
    public var collection: String? {
        if case .collection(let name) = target {
            return name
        }
        return nil
    }

    /// The first call of a cursor method, e.g. `modifier("limit")`.
    public func modifier(_ name: String) -> Call? { calls.dropFirst().first { $0.name == name } }

    /// Database methods; anything else after `db.` names a collection.
    static let databaseMethods: Set<String> = [
        "runCommand", "adminCommand", "getCollectionNames", "getCollectionInfos", "createCollection", "createView",
        "dropDatabase", "stats", "serverStatus", "version", "getName", "hostInfo", "currentOp", "getUsers", "getRoles",
        "listCommands", "isMaster", "hello", "aggregate", "getCollection", "getSiblingDB", "getProfilingStatus",
    ]

    // MARK: Parsing

    public static func parse(_ text: String) throws -> MongoStatement {
        var parser = MongoShellParser(text)
        parser.skipSpace()
        if let word = parser.identifier(), word == "show" || word == "use" {
            let rest = Substring(String(decoding: Array(text.utf8)[parser.index...], as: UTF8.self))
            var head = rest[..<(rest.firstIndex { $0 == ";" || $0.isNewline } ?? rest.endIndex)]
            if let comment = head.range(of: "//") { head = head[..<comment.lowerBound] }
            let argument = head.trimmingCharacters(in: .whitespaces)
            guard !argument.isEmpty, !argument.contains(where: \.isWhitespace) else {
                throw parser.error("\(word) needs one name")
            }
            var remainder = MongoShellParser(String(rest[head.endIndex...]))
            try remainder.expectEnd()
            var statement = MongoStatement(target: word == "show" ? .show(argument.lowercased()) : .use(argument))
            statement.hasComments = parser.sawComment || remainder.sawComment
            return statement
        }
        parser = MongoShellParser(text)
        parser.skipSpace()
        guard parser.identifier() == "db" else {
            throw parser.error("Expected a statement starting with db., show or use")
        }

        var database: String?
        var path: [String] = []
        var collection: String?
        var calls: [Call] = []
        while calls.isEmpty {
            if parser.take("[") {
                path.append(try parser.string())
                try parser.expect("]")
                continue
            }
            try parser.expect(".")
            guard let name = parser.identifier() else {
                throw parser.error("Expected a collection or method name")
            }
            guard let arguments = try parser.optionalArguments() else {
                path.append(name)
                continue
            }
            let first = path.isEmpty && collection == nil
            if first, name == "getSiblingDB" || name == "getDB" {
                guard let other = arguments.first as? String else {
                    throw parser.error("\(name) needs a database name")
                }
                database = other
            } else if first, name == "getCollection" {
                guard let named = arguments.first as? String else {
                    throw parser.error("getCollection needs a collection name")
                }
                collection = named
            } else {
                if !path.isEmpty {
                    collection = path.joined(separator: ".")
                }
                calls.append(Call(name, arguments))
            }
        }
        while parser.take(".") {
            guard let name = parser.identifier() else {
                throw parser.error("Expected a method name")
            }
            guard let arguments = try parser.optionalArguments() else {
                throw parser.error("Expected “(” after \(name)")
            }
            calls.append(Call(name, arguments))
        }
        try parser.expectEnd()
        var statement = MongoStatement(
            target: collection.map(Target.collection) ?? .database,
            database: database,
            calls: calls
        )
        statement.hasComments = parser.sawComment
        statement.makesValues = parser.madeValue
        return statement
    }

    // MARK: Writing

    /// The statement as shell text; `pretty` spreads long document arguments over lines.
    public func formatted(pretty: Bool = true) -> String {
        switch target {
        case .show(let what): return "show \(what)"
        case .use(let name): return "use \(name)"
        case .database, .collection: break
        }
        var text = "db"
        if let database {
            text += ".getSiblingDB(\(MongoShell.quoted(database)))"
        }
        if let collection {
            text += Self.collectionAccessor(collection)
        }
        for call in calls {
            text +=
                "." + call.name + "("
                + call.arguments
                .map { argument in
                    let compact = MongoShell.format(argument)
                    return pretty && compact.count > Defaults.Mongo.inlineWidth
                        ? MongoShell.format(argument, pretty: true) : compact
                }
                .joined(separator: ", ") + ")"
        }
        return text
    }

    /// `.users` when the name reads as one, `.getCollection("…")` otherwise.
    public static func collectionAccessor(_ name: String) -> String {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let plain =
            !name.isEmpty && parts.allSatisfy { MongoShell.isIdentifier(String($0)) }
            && !databaseMethods.contains(String(parts[0]))
        return plain ? "." + name : ".getCollection(\(MongoShell.quoted(name)))"
    }

    /// `db.users` or `db.getCollection("weird name")`, for building statements.
    public static func reference(to collection: String) -> String {
        "db" + collectionAccessor(collection)
    }
}

/// Splits shell text into statements: at `;`, and at line ends where the statement is complete (the next
/// line doesn't continue it with `.method(…)`).
public enum MongoSplitter {
    public static func statements(in script: String) -> [ScriptStatement] {
        // One element per Unicode scalar, not per grapheme: a combining mark after a quote would otherwise merge
        // with it into one "character" that isn't a quote, and a crafted name could end the string early.
        let chars = script.unicodeScalars.map(Character.init)
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(chars.count + 1)
        var running = 0
        for character in chars {
            utf16Offsets.append(running)
            running += character.utf16.count
        }
        utf16Offsets.append(running)

        var statements: [ScriptStatement] = []
        var start = 0
        var depth = 0
        /// The last character that wasn't space or comment, to tell a regex `/` from division and spot continuations.
        var lastSignificant: Character?
        var hasCode = false

        func flush(upTo end: Int) {
            defer {
                start = end + 1
                hasCode = false
                lastSignificant = nil
                depth = 0
            }
            guard hasCode, start < end else { return }
            let piece = String(chars[start..<end])
            let leading = piece.prefix(while: { $0.isWhitespace }).count
            let trailing = piece.reversed().prefix(while: { $0.isWhitespace }).count
            let from = start + leading
            let to = end - trailing
            guard from < to else { return }
            statements.append(
                ScriptStatement(
                    text: String(chars[from..<to]),
                    range: NSRange(location: utf16Offsets[from], length: utf16Offsets[to] - utf16Offsets[from])
                )
            )
        }

        /// The next character that isn't space, skipping whole comment lines.
        func nextSignificant(after index: Int) -> Character? {
            var j = index
            while j < chars.count {
                if chars[j].isWhitespace {
                    j += 1
                    continue
                }
                if chars[j] == "/", j + 1 < chars.count, chars[j + 1] == "/" {
                    while j < chars.count, chars[j] != "\n" { j += 1 }
                    continue
                }
                return chars[j]
            }
            return nil
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "/" && next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && next == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { i += 1 }
                i = min(chars.count, i + 2)
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                i += 1
                while i < chars.count, chars[i] != c, chars[i] != "\n" || c == "`" {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                hasCode = true
                lastSignificant = c
                continue
            }
            if c == "/", lastSignificant.map({ "(,:[!&|?{};=".contains($0) }) ?? true {
                // A regular expression literal.
                i += 1
                var inClass = false
                while i < chars.count, chars[i] != "\n" {
                    if chars[i] == "\\" {
                        i += 2
                        continue
                    }
                    if chars[i] == "[" {
                        inClass = true
                    } else if chars[i] == "]" {
                        inClass = false
                    } else if chars[i] == "/" && !inClass {
                        break
                    }
                    i += 1
                }
                i += 1
                hasCode = true
                lastSignificant = "/"
                continue
            }
            switch c {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth = max(0, depth - 1)
            default: break
            }
            if c == ";" && depth == 0 {
                flush(upTo: i)
                i += 1
                continue
            }
            if c == "\n" && depth == 0 && hasCode {
                let continues =
                    nextSignificant(after: i + 1) == "." || lastSignificant.map { ".,(+-*=:&|?".contains($0) } == true
                if !continues {
                    flush(upTo: i)
                    i += 1
                    continue
                }
            }
            if !c.isWhitespace {
                hasCode = true
                lastSignificant = c
            }
            i += 1
        }
        flush(upTo: chars.count)
        return statements
    }
}

extension MongoStatement {
    /// Beautify for the shell: each statement rewritten with even spacing and long documents over several lines.
    /// Statements with comments, with values made when they run (`ObjectId()`, `new Date()`), or that don't parse,
    /// are left as written.
    public static func beautify(_ script: String) -> String {
        let text = NSMutableString(string: script)
        for statement in MongoSplitter.statements(in: script).reversed() {
            guard let parsed = try? parse(statement.text), !parsed.hasComments, !parsed.makesValues else { continue }
            text.replaceCharacters(in: statement.range, with: parsed.formatted())
        }
        return text as String
    }

    /// Adds `.limit(n)` to a find or aggregate that has none, as the toolbar's row limit promises.
    public static func applyingRowLimit(_ text: String, limit: Int) -> String {
        guard let statement = try? parse(text), statement.collection != nil,
            let method = statement.method, method == "find" || method == "aggregate",
            statement.modifier("limit") == nil,
            !["count", "explain", "itcount", "size"].contains(where: { statement.modifier($0) != nil })
        else { return text }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(";") { trimmed.removeLast() }
        // A trailing line comment would swallow the added call; put it on its own line.
        return trimmed + (statement.hasComments ? "\n" : "") + ".limit(\(limit))"
    }
}
