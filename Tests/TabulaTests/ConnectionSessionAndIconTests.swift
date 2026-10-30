import AppKit
import XCTest

@testable import Tabula
@testable import TabulaFoundation
@testable import TabulaSQLite

/// The connection rail of a window, and the seasonal icon.
@MainActor
final class ConnectionSessionAndIconTests: XCTestCase {
    private var paths: [String] = []

    override class func setUp() {
        super.setUp()
        TestDataDirectory.prepare()
    }

    override func tearDown() async throws {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
        paths = []
    }

    private func database(_ name: String) async throws -> ConnectionConfig {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-\(name)-\(UUID()).sqlite").path
        paths.append(path)
        let driver = try SQLiteDriver(path: path)
        _ = try await driver.execute("CREATE TABLE \(name) (id INTEGER PRIMARY KEY)")
        await driver.close()
        var config = ConnectionConfig(kind: .sqlite, filePath: path)
        config.name = name
        return config
    }

    func testOpeningSwitchingAndClosingConnections() async throws {
        try TestDataDirectory.check()
        let appState = AppState()
        let session = ConnectionSession()
        let first = try await database("first")
        let second = try await database("second")
        await session.open(first, appState: appState)
        await session.open(second, appState: appState)
        XCTAssertEqual(session.connections.map(\.config.name), ["first", "second"])
        XCTAssertEqual(session.active?.id, second.id)
        XCTAssertEqual(session.active?.status, .connected)

        // Opening one that is already open only switches to it.
        await session.open(first, appState: appState)
        XCTAssertEqual(session.connections.count, 2)
        XCTAssertEqual(session.active?.id, first.id)
        session.selectAdjacent(1)
        XCTAssertEqual(session.active?.id, second.id)
        session.selectAdjacent(1)
        XCTAssertEqual(session.active?.id, first.id, "next wraps around")

        session.close(first.id)
        XCTAssertEqual(session.connections.map(\.config.name), ["second"])
        XCTAssertEqual(session.active?.id, second.id, "the next one is shown")
        XCTAssertTrue(session.confirmCloseResults(), "nothing staged, so closing needs no question")
        session.closeAll()
        XCTAssertTrue(session.connections.isEmpty)
        XCTAssertNil(session.active)
    }

    /// The Dock gets finished bitmaps, not an image that draws itself, which AppKit cached at 64 MB.
    func testDockIconIsAFewFinishedBitmaps() throws {
        let icon = try XCTUnwrap(SeasonalIcon.image(for: .halloween))
        let dock = try XCTUnwrap(SeasonalIcon.bitmap(icon))
        let bitmaps = dock.representations.compactMap { $0 as? NSBitmapImageRep }
        XCTAssertEqual(bitmaps.map(\.pixelsWide), [32, 64, 128, 256, 512])
        XCTAssertEqual(bitmaps.count, dock.representations.count)
        let largest = try XCTUnwrap(bitmaps.last)
        XCTAssertGreaterThan(try XCTUnwrap(largest.colorAt(x: 256, y: 256)).alphaComponent, 0.9)
        XCTAssertLessThan(try XCTUnwrap(largest.colorAt(x: 0, y: 0)).alphaComponent, 0.1)
        // Small marks are drawn at their own size, and the same image is reused.
        let mark = try XCTUnwrap(SeasonalIcon.image(for: .halloween, side: 80))
        XCTAssertEqual(mark.size, NSSize(width: 80, height: 80))
        XCTAssertTrue(SeasonalIcon.image(for: .halloween, side: 80) === mark)
        XCTAssertNil(SeasonalIcon.image(for: .regular, side: 80))
    }

    func testHalloweenIconIsDrawnAtAnySize() throws {
        XCTAssertNil(SeasonalIcon.image(for: .regular), "outside a season the bundle's icon is used")
        let icon = try XCTUnwrap(SeasonalIcon.image(for: .halloween))
        for size in [16, 128, 1024] {
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: size,
                    pixelsHigh: size,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            )
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            let center = try XCTUnwrap(bitmap.colorAt(x: size / 2, y: size / 2))
            XCTAssertGreaterThan(center.alphaComponent, 0.9, "the tile covers the middle at \(size) px")
            let corner = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
            XCTAssertLessThan(corner.alphaComponent, 0.1, "the margin around the tile stays clear at \(size) px")
        }
    }
}
