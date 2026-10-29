import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Refuses PostgreSQL scripts that contain psql commands, before psql runs them: a script can run commands on this
/// Mac (`\!`), read and write its files (`\copy`, `\o`, `\i`) or connect elsewhere (`\connect`). pg_dump writes no
/// such commands except `\restrict` / `\unrestrict` (since 17.6), which are allowed.
///
/// psql treats a backslash as a command anywhere outside quotes, comments and COPY data, so the script is read the
/// same way: strings ('…', E'…'), quoted names, dollar quoting, comments, and the data after `COPY … FROM stdin;` up
/// to its `\.` line. Anything unclear counts as a command: the check may refuse a script psql would run safely, not
/// the other way round.
public enum PostgresScriptCheck {
    static let allowed: Set<String> = ["restrict", "unrestrict"]

    public static func check(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var scanner = Scanner()
        var carry = Data()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: UInt8(ascii: "\n")) {
                try scanner.line(carry[start..<newline])
                start = carry.index(after: newline)
            }
            carry = Data(carry[start...])
        }
        if !carry.isEmpty {
            try scanner.line(carry[...])
        }
    }

    /// Checks text already in memory; for tests.
    static func check(text: String) throws {
        var scanner = Scanner()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            try scanner.line(Data(line.utf8)[...])
        }
    }

    struct Scanner {
        enum State: Equatable {
            case normal
            case single(escapes: Bool)
            case quotedName
            case dollar([UInt8])
            case blockComment(Int)
            case copyData
        }
        var state = State.normal
        var lineNumber = 0
        /// The current statement's start and end, outside strings and comments, to spot `COPY … FROM stdin;`.
        var head: [UInt8] = []
        var tail: [UInt8] = []
        var copyFollows = false

        mutating func line(_ bytes: Data.SubSequence) throws {
            lineNumber += 1
            let line = Array(bytes)
            // psql stops reading a line at a NUL, so what follows would be read differently. pg_dump never writes one.
            if line.contains(0) {
                throw DatabaseError("Line \(lineNumber) of the script contains a NUL byte; it isn't a pg_dump script.")
            }
            if state == .copyData {
                if line == Array("\\.".utf8) || line == Array("\\.\r".utf8) { state = .normal }
                return
            }
            var i = 0
            while i < line.count {
                let c = line[i]
                let next = i + 1 < line.count ? line[i + 1] : nil
                switch state {
                case .copyData:
                    return
                case .single(let escapes):
                    // Settings name their values in quotes ('SJIS'), so string contents count for checkSettings.
                    record(c)
                    if escapes && c == UInt8(ascii: "\\") {
                        i += 2
                        continue
                    }
                    if c == UInt8(ascii: "'") {
                        if next == UInt8(ascii: "'") {
                            i += 2
                            continue
                        }
                        state = .normal
                    }
                case .quotedName:
                    if c == UInt8(ascii: "\"") {
                        if next == UInt8(ascii: "\"") {
                            i += 2
                            continue
                        }
                        state = .normal
                    }
                case .dollar(let tag):
                    if c == UInt8(ascii: "$"), line.count >= i + tag.count + 2,
                        Array(line[(i + 1)..<(i + 1 + tag.count)]) == tag, line[i + 1 + tag.count] == UInt8(ascii: "$")
                    {
                        i += tag.count + 2
                        state = .normal
                        continue
                    }
                case .blockComment(let depth):
                    if c == UInt8(ascii: "*"), next == UInt8(ascii: "/") {
                        state = depth > 1 ? .blockComment(depth - 1) : .normal
                        i += 2
                        continue
                    }
                    if c == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                        state = .blockComment(depth + 1)
                        i += 2
                        continue
                    }
                case .normal:
                    // A -- comment ends at a carriage return as well as at the end of the line.
                    if c == UInt8(ascii: "-"), next == UInt8(ascii: "-") {
                        i = line[i...].firstIndex(of: UInt8(ascii: "\r")) ?? line.count
                        continue
                    }
                    if c == UInt8(ascii: "/"), next == UInt8(ascii: "*") {
                        state = .blockComment(1)
                        i += 2
                        continue
                    }
                    if c == UInt8(ascii: "\\") {
                        let name = line[(i + 1)...].prefix { isLetter($0) }
                        let command = String(decoding: name, as: UTF8.self)
                        guard Self.allowedCommand(command) else {
                            throw DatabaseError(
                                "Line \(lineNumber) of the script holds the psql command \\\(command.isEmpty ? String(decoding: line[(i + 1)...].prefix(1), as: UTF8.self) : command), which could run commands or read files on this Mac. Tabula restores scripts without psql commands, as pg_dump writes them."
                            )
                        }
                        // \restrict and \unrestrict take one key, and nothing may follow: psql would read a backslash
                        // after it as the next command.
                        var j = i + 1 + name.count
                        while j < line.count, line[j] == UInt8(ascii: " ") || line[j] == UInt8(ascii: "\t") { j += 1 }
                        while j < line.count, line[j] != UInt8(ascii: " "), line[j] != UInt8(ascii: "\t"),
                            line[j] != UInt8(ascii: "\r")
                        {
                            guard isLetter(line[j]) || isDigit(line[j]) else {
                                throw DatabaseError(
                                    "Line \(lineNumber) of the script has an unexpected \\\(command) key."
                                )
                            }
                            j += 1
                        }
                        guard
                            line[j...]
                                .allSatisfy({
                                    $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r")
                                })
                        else {
                            throw DatabaseError(
                                "Line \(lineNumber) of the script has more after \\\(command), which psql would read as another command."
                            )
                        }
                        i = line.count
                        continue
                    }
                    if c == UInt8(ascii: "'") {
                        // E'…' (and e'…') strings take backslash escapes; others don't, as pg_dump's
                        // standard_conforming_strings = on makes them.
                        let escaped =
                            i > 0 && (line[i - 1] == UInt8(ascii: "E") || line[i - 1] == UInt8(ascii: "e"))
                            && (i < 2 || !isIdentifierOrDollar(line[i - 2]))
                        state = .single(escapes: escaped)
                        record(c)
                    } else if c == UInt8(ascii: "\"") {
                        state = .quotedName
                        record(c)
                    } else if c == UInt8(ascii: "$"), i == 0 || !isIdentifierOrDollar(line[i - 1]),
                        let tag = dollarTag(line, from: i)
                    {
                        state = .dollar(tag)
                        record(c)
                        i += tag.count + 2
                        continue
                    } else if c == UInt8(ascii: ";") {
                        try checkSettings()
                        copyFollows = isCopyFromStdin()
                        head = []
                        tail = []
                    } else {
                        record(c)
                    }
                }
                i += 1
            }
            if copyFollows {
                copyFollows = false
                state = .copyData
            }
        }

        static func allowedCommand(_ name: String) -> Bool { allowed.contains(name) }

        /// Encodings whose characters can contain the byte of a backslash, which psql then reads differently.
        static let unsafeEncodings = [
            "SJIS", "SHIFT_JIS", "SHIFTJIS", "MSKANJI", "BIG5", "GBK", "GB18030", "UHC", "JOHAB",
            "WIN932", "WIN936", "WIN949", "WIN950", "CP932", "CP936", "CP949", "CP950",
        ]

        /// Settings that change how psql reads the rest of the script are refused: strings with backslash escapes
        /// (standard_conforming_strings off) and client encodings whose characters can contain a backslash byte.
        func checkSettings() throws {
            let statement = String(decoding: head, as: UTF8.self).uppercased()
            if statement.contains("STANDARD_CONFORMING_STRINGS"),
                statement.contains("OFF") || statement.contains("FALSE") || statement.contains("'0'")
            {
                throw DatabaseError(
                    "Line \(lineNumber) of the script turns standard_conforming_strings off, which Tabula doesn't restore."
                )
            }
            if statement.contains("CLIENT_ENCODING") || statement.contains("SET NAMES"),
                Self.unsafeEncodings.contains(where: { statement.replacingOccurrences(of: "-", with: "_").contains($0) }
                )
            {
                throw DatabaseError(
                    "Line \(lineNumber) of the script sets a client encoding Tabula can't check (such as SJIS or BIG5). Make the dump with --encoding=UTF8."
                )
            }
        }

        mutating func record(_ c: UInt8) {
            if head.count < 160 {
                head.append(c)
            }
            tail.append(c)
            if tail.count > 64 {
                tail.removeFirst(tail.count - 64)
            }
        }

        /// `COPY … FROM stdin` (pg_dump's data blocks), judged by the statement's start and end.
        func isCopyFromStdin() -> Bool {
            let start = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let end = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return start.hasPrefix("COPY ") && end.range(of: #"FROM\s+STDIN$"#, options: .regularExpression) != nil
        }

        /// The tag of a dollar quote starting at `index` ($$ or $tag$), or nil for $1 and the like.
        func dollarTag(_ line: [UInt8], from index: Int) -> [UInt8]? {
            var j = index + 1
            var tag: [UInt8] = []
            while j < line.count, line[j] != UInt8(ascii: "$") {
                let c = line[j]
                guard isLetter(c) || c == UInt8(ascii: "_") || c >= 0x80 || (!tag.isEmpty && isDigit(c)) else {
                    return nil
                }
                tag.append(c)
                j += 1
            }
            return j < line.count ? tag : nil
        }

        func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func isIdentifier(_ c: UInt8) -> Bool { isLetter(c) || isDigit(c) || c == UInt8(ascii: "_") || c >= 0x80 }
        /// psql's identifiers can contain $ after the first character, so `a$'x'` and `a$$` aren't strings.
        func isIdentifierOrDollar(_ c: UInt8) -> Bool { isIdentifier(c) || c == UInt8(ascii: "$") }
    }
}
