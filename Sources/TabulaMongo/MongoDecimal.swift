import BSON
import Foundation
import NIOCore
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Decimal128 (IEEE 754-2008 decimal, binary integer significand) to and from text.
///
/// The BSON package stores the 16 bytes but has no conversions, so they are read and written here through
/// a one-field document's raw bytes.
enum MongoDecimal {
    private static let exponentBias = 6176
    private static let maxExponent = 6111
    private static let minExponent = -6176
    private static let maxDigits = 34
    /// Bytes before the value in `{ v: <decimal> }`: length (4), type (1), "v" and its terminator (2).
    private static let valueOffset = 7
    private static let byteCount = 16

    // MARK: Bits

    static func words(_ decimal: Decimal128) -> (high: UInt64, low: UInt64) {
        var document = Document()
        document.appendValue(decimal, forKey: "v")
        let buffer = document.makeByteBuffer()
        let high =
            buffer.getInteger(at: buffer.readerIndex + valueOffset + 8, endianness: .little, as: UInt64.self) ?? 0
        let low = buffer.getInteger(at: buffer.readerIndex + valueOffset, endianness: .little, as: UInt64.self) ?? 0
        return (high, low)
    }

    static func make(high: UInt64, low: UInt64) -> Decimal128? {
        var bytes: [UInt8] = []
        let total = valueOffset + byteCount + 1
        bytes += withUnsafeBytes(of: Int32(total).littleEndian, Array.init)
        bytes += [0x13, UInt8(ascii: "v"), 0]
        bytes += withUnsafeBytes(of: low.littleEndian, Array.init)
        bytes += withUnsafeBytes(of: high.littleEndian, Array.init)
        bytes.append(0)
        return Document(bytes: bytes)["v"] as? Decimal128
    }

    // MARK: Text

    static func string(_ decimal: Decimal128) -> String {
        let (high, low) = words(decimal)
        let negative = high >> 63 == 1
        let sign = negative ? "-" : ""
        let combination = (high >> 58) & 0x1F
        if combination == 0x1F {
            return "NaN"
        }
        if combination == 0x1E {
            return sign + "Infinity"
        }

        var exponent: Int
        var significand: (high: UInt64, low: UInt64)
        if (high >> 61) & 0x3 == 0x3 {
            // The "11" form only encodes significands beyond 34 digits, which count as zero.
            exponent = Int((high >> 47) & 0x3FFF) - exponentBias
            significand = (0, 0)
        } else {
            exponent = Int((high >> 49) & 0x3FFF) - exponentBias
            significand = (high & 0x1_FFFF_FFFF_FFFF, low)
        }
        var digits = decimalDigits(significand)
        if digits.count > maxDigits {
            digits = "0"
        }

        let adjusted = exponent + digits.count - 1
        if exponent <= 0 && adjusted >= -6 {
            guard exponent < 0 else { return sign + digits }
            let point = digits.count + exponent
            if point > 0 {
                let index = digits.index(digits.startIndex, offsetBy: point)
                return sign + digits[..<index] + "." + digits[index...]
            }
            return sign + "0." + String(repeating: "0", count: -point) + digits
        }
        var text = String(digits.prefix(1))
        if digits.count > 1 {
            text += "." + digits.dropFirst()
        }
        return sign + text + "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
    }

    static func parse(_ text: String) -> Decimal128? {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if text.first == "-" || text.first == "+" {
            negative = text.first == "-"
            text = text.dropFirst()
        }
        let signBit: UInt64 = negative ? 1 << 63 : 0
        switch text.lowercased() {
        case "nan": return make(high: 0x7C00_0000_0000_0000, low: 0)
        case "inf", "infinity": return make(high: signBit | 0x7800_0000_0000_0000, low: 0)
        default: break
        }

        var digits = ""
        var exponent = 0
        var seenPoint = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isASCII, character.isNumber {
                digits.append(character)
                if seenPoint {
                    exponent -= 1
                }
            } else if character == ".", !seenPoint {
                seenPoint = true
            } else if character == "e" || character == "E" {
                guard let value = Int(text[text.index(after: index)...]) else { return nil }
                exponent += value
                index = text.endIndex
                break
            } else {
                return nil
            }
            index = text.index(after: index)
        }
        guard !digits.isEmpty else { return nil }

        digits = String(digits.drop(while: { $0 == "0" }))
        if digits.isEmpty {
            digits = "0"
        }
        // Too many digits: drop trailing zeros (exact); anything else would need rounding.
        while digits.count > maxDigits, digits.last == "0" {
            digits.removeLast()
            exponent += 1
        }
        guard digits.count <= maxDigits else { return nil }
        // Out-of-range exponents can sometimes be absorbed exactly by the significand's zeros.
        while exponent > maxExponent, digits != "0", digits.count < maxDigits {
            digits += "0"
            exponent -= 1
        }
        while exponent < minExponent, digits.last == "0", digits.count > 1 {
            digits.removeLast()
            exponent += 1
        }
        if digits == "0" { exponent = min(max(exponent, minExponent), maxExponent) }
        guard (minExponent...maxExponent).contains(exponent) else { return nil }

        var high: UInt64 = 0
        var low: UInt64 = 0
        for character in digits {
            // (high, low) = (high, low) * 10 + digit
            let lowProduct = low.multipliedFullWidth(by: 10)
            high = high &* 10 &+ lowProduct.high
            let (sum, overflow) = lowProduct.low.addingReportingOverflow(UInt64(character.wholeNumberValue ?? 0))
            low = sum
            if overflow {
                high &+= 1
            }
        }
        let biased = UInt64(exponent + exponentBias)
        return make(high: signBit | (biased << 49) | high, low: low)
    }

    /// The 113-bit significand as decimal digits.
    private static func decimalDigits(_ value: (high: UInt64, low: UInt64)) -> String {
        var (high, low) = value
        guard high != 0 || low != 0 else { return "0" }
        var digits: [Character] = []
        while high != 0 || low != 0 {
            let (quotientHigh, remainderHigh) = high.quotientAndRemainder(dividingBy: 10)
            let (quotientLow, remainder) = UInt64(10).dividingFullWidth((remainderHigh, low))
            high = quotientHigh
            low = quotientLow
            digits.append(Character(String(remainder)))
        }
        return String(digits.reversed())
    }
}
