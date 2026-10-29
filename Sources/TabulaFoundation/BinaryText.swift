import Foundation

/// How a cell shows bytes on every database: `\x` and lowercase hex, as psql shows a bytea. Results name the
/// columns that hold bytes (`QueryResult.binaryColumns`), so writing a cell back knows bytes from text that only
/// looks like this.
public enum BinaryText {
    public static func text(_ bytes: some Collection<UInt8>) -> String {
        "\\x" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The hex digits of `text` when it is bytes written this way (an even number of hex digits after `\x`).
    public static func hexDigits(_ text: String) -> Substring? {
        guard text.hasPrefix("\\x") else { return nil }
        let digits = text.dropFirst(2)
        guard digits.count.isMultiple(of: 2), digits.allSatisfy(\.isHexDigit) else { return nil }
        return digits
    }
}
