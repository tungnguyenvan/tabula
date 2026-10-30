import XCTest

@testable import Tabula

/// .sql files are read in the encoding they were written in and saved back in it (#238).
final class SQLFileEncodingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-sqlfile-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ bytes: [UInt8]) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".sql")
        try Data(bytes).write(to: url)
        return url
    }

    func testReadsEachEncoding() throws {
        let utf8 = try SQLFile.read(try file(Array("SELECT 'Hà Nội';".utf8)))
        XCTAssertEqual(utf8.text, "SELECT 'Hà Nội';")
        XCTAssertEqual(utf8.encoding, .utf8)
        // A byte order mark isn't part of the text, or the first statement would start with it.
        let bom = try SQLFile.read(try file([0xEF, 0xBB, 0xBF] + Array("SELECT 1;".utf8)))
        XCTAssertEqual(bom.text, "SELECT 1;")
        let windows = try SQLFile.read(try file(Array("SELECT 'caf".utf8) + [0xE9, 0x80] + Array("';".utf8)))
        XCTAssertEqual(windows.text, "SELECT 'café€';")
        XCTAssertEqual(windows.encoding, .windowsCP1252)
        let utf16 = try SQLFile.read(
            try file([0xFF, 0xFE] + "SELECT 1;".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        )
        XCTAssertEqual(utf16.text, "SELECT 1;")
        // Bytes Windows-1252 leaves undefined still open, as Latin-1.
        let latin1 = try SQLFile.read(try file(Array("SELECT '".utf8) + [0x81, 0xE9] + Array("';".utf8)))
        XCTAssertEqual(latin1.encoding, .isoLatin1)
        XCTAssertEqual(latin1.text, "SELECT '\u{81}é';")
    }

    func testSavesInTheEncodingItWasReadIn() throws {
        let original: [UInt8] = Array("SELECT 'caf".utf8) + [0xE9] + Array("';".utf8)
        let (text, encoding) = try SQLFile.read(try file(original))
        XCTAssertEqual([UInt8](SQLFile.data(text, encoding: encoding)), original, "unchanged text saves the same bytes")
        // UTF-16 keeps its byte order and mark, big- or little-endian (#271).
        for mark in [[UInt8(0xFE), 0xFF], [0xFF, 0xFE]] {
            let bigEndian = mark[0] == 0xFE
            let body = "SELECT 'Hà Nội';".utf16
                .flatMap { bigEndian ? [UInt8($0 >> 8), UInt8($0 & 0xFF)] : [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let (text16, encoding16) = try SQLFile.read(try file(mark + body))
            XCTAssertEqual(text16, "SELECT 'Hà Nội';")
            XCTAssertEqual([UInt8](SQLFile.data(text16, encoding: encoding16)), mark + body, "byte order \(mark)")
        }
        let edited = text + "\n-- tiếng Việt"
        XCTAssertEqual(
            SQLFile.data(edited, encoding: encoding),
            Data(edited.utf8),
            "text the encoding can't hold: UTF-8"
        )
    }
}
