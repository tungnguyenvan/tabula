import Foundation

/// How a cell shows bytes on every database: `\x` and lowercase hex, as psql shows a bytea. Results name the
/// columns that hold bytes (`QueryResult.binaryColumns`), so writing a cell back knows bytes from text that only
/// looks like this.
public enum BinaryText {
    public static func text(_ bytes: some Collection<UInt8>) -> String {
        "\\x" + hex(bytes)
    }

    /// Lowercase hex digits, two per byte. A table lookup: formatting each byte with String(format:) took a second
    /// for a megabyte.
    public static func hex(_ bytes: some Collection<UInt8>) -> String {
        var utf8: [UInt8] = []
        utf8.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            utf8.append(hexDigits[Int(byte >> 4)])
            utf8.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// The hex digits of `text` when it is bytes written this way (an even number of hex digits after `\x`).
    public static func hexDigits(_ text: String) -> Substring? {
        guard text.hasPrefix("\\x") else { return nil }
        let digits = text.dropFirst(2)
        guard digits.count.isMultiple(of: 2), digits.allSatisfy(\.isHexDigit) else { return nil }
        return digits
    }
}
