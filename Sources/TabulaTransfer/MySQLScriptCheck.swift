import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Refuses MySQL scripts that switch to or create another database (`USE`, `CREATE DATABASE`), as dumps made with
/// --databases or --all-databases do: the restore would write to databases other than the one you confirmed.
public enum MySQLScriptCheck {
    public static func check(_ file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var carry = Data()
        var lineNumber = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: UInt8(ascii: "\n")) {
                lineNumber += 1
                try check(line: carry[start..<newline], number: lineNumber)
                start = carry.index(after: newline)
            }
            carry = Data(carry[start...])
        }
        if !carry.isEmpty { try check(line: carry[...], number: lineNumber + 1) }
    }

    static func check(line: Data.SubSequence, number: Int) throws {
        // Statements mysqldump writes start a line; INSERT data never does with these words.
        let text = String(decoding: line.prefix(80), as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased()
        for keyword in ["USE ", "USE`", "CREATE DATABASE", "CREATE SCHEMA", "DROP DATABASE", "DROP SCHEMA"] where text.hasPrefix(keyword) {
            throw DatabaseError("Line \(number) of the script switches to or creates another database (\(keyword.trimmingCharacters(in: .whitespaces))). Tabula restores only into the selected database: dump it without --databases, or restore this file with mysql in Terminal.")
        }
    }

    /// Checks text already in memory; for tests.
    static func check(text: String) throws {
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            try check(line: Data(line.utf8)[...], number: index + 1)
        }
    }
}
