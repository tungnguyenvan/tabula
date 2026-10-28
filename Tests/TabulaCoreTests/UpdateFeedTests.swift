import XCTest
@testable import TabulaCore

final class UpdateFeedTests: XCTestCase {
    func testVersionOrdering() throws {
        let v = { (s: String) in try XCTUnwrap(SemanticVersion(s)) }
        XCTAssertLessThan(try v("0.1.0"), try v("0.2.0"))
        XCTAssertLessThan(try v("0.9.9"), try v("0.10.0"))
        XCTAssertLessThan(try v("1.0.0-beta.2"), try v("1.0.0"))
        XCTAssertLessThan(try v("1.0.0-beta.2"), try v("1.0.0-beta.10"))
        XCTAssertEqual(try v("v1.2"), try v("1.2.0"))
        XCTAssertNil(SemanticVersion("latest"))
        XCTAssertNil(SemanticVersion("1.-2"))
    }

    private func release(tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]) -> Data {
        let list = assets.map { #"{"name": "\#($0)", "size": 123, "browser_download_url": "https://github.com/x/\#($0)"}"# }
        return Data(#"""
        {"tag_name": "\#(tag)", "name": "Tabula \#(tag)", "body": "## Notes", "html_url": "https://github.com/x/releases/\#(tag)",
         "draft": \#(draft), "prerelease": \#(prerelease), "assets": [\#(list.joined(separator: ","))]}
        """#.utf8)
    }

    func testFeedParsing() throws {
        let current = try XCTUnwrap(SemanticVersion("0.2.0"))
        let good = release(tag: "v0.3.0", assets: ["Tabula-0.3.0.dmg", "Tabula-0.3.0.zip", "SHA256SUMS.txt"])
        let update = try XCTUnwrap(try UpdateFeed.update(from: good, current: current))
        XCTAssertEqual(update.version.description, "0.3.0")
        XCTAssertEqual(update.archiveName, "Tabula-0.3.0.zip")
        XCTAssertEqual(update.archiveURL.lastPathComponent, "Tabula-0.3.0.zip")
        XCTAssertEqual(update.notes, "## Notes")

        XCTAssertNil(try UpdateFeed.update(from: release(tag: "v0.2.0", assets: ["Tabula-0.2.0.zip", "SHA256SUMS.txt"]), current: current))
        XCTAssertNil(try UpdateFeed.update(from: release(tag: "v0.1.9", assets: ["Tabula-0.1.9.zip", "SHA256SUMS.txt"]), current: current))
        XCTAssertNil(try UpdateFeed.update(from: release(tag: "v0.3.0", draft: true, assets: ["Tabula-0.3.0.zip", "SHA256SUMS.txt"]), current: current))
        XCTAssertNil(try UpdateFeed.update(from: release(tag: "v0.3.0", prerelease: true, assets: ["Tabula-0.3.0.zip", "SHA256SUMS.txt"]), current: current))
        XCTAssertNil(try UpdateFeed.update(from: release(tag: "v0.3.0", assets: ["Tabula-0.3.0.zip"]), current: current), "no checksums")
        XCTAssertNil(try UpdateFeed.update(from: release(tag: "v0.3.0", assets: ["Tabula-0.3.0.dmg", "SHA256SUMS.txt"]), current: current), "no zip")
    }

    func testChecksumParsing() {
        let hex = String(repeating: "ab", count: 32)
        let sums = "\(String(repeating: "cd", count: 32))  Tabula-0.3.0.dmg\n\(hex.uppercased())  Tabula-0.3.0.zip\nbad line\n"
        XCTAssertEqual(UpdateFeed.checksum(for: "Tabula-0.3.0.zip", in: sums), hex)
        XCTAssertEqual(UpdateFeed.checksum(for: "f.zip", in: "\(hex) *f.zip"), hex)
        XCTAssertNil(UpdateFeed.checksum(for: "Tabula-0.4.0.zip", in: sums))
        XCTAssertNil(UpdateFeed.checksum(for: "x", in: "1234  x"))
    }

    /// The real repository: before any release is published GitHub returns 404, which must mean "no update".
    func testLiveFeedDoesNotThrow() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_NETWORK"] != nil else { throw XCTSkip("TABULA_TEST_NETWORK not set") }
        let repository = ProcessInfo.processInfo.environment["TABULA_TEST_REPOSITORY"] ?? "tungnguyenvan/tabula"
        let feed = try XCTUnwrap(UpdateFeed.latestReleaseURL(repository: repository))
        _ = try await UpdateFeed.check(feed: feed, current: try XCTUnwrap(SemanticVersion("0.0.1")))
    }
}
