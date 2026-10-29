import XCTest

@testable import Tabula
@testable import TabulaUpdates

/// Downloading an update checks the release's checksum, the app inside and its signature before anything is
/// installed. A fake release is served from a local HTTP server; nothing is installed or relaunched.
final class UpdaterPrepareTests: XCTestCase {
    private var folder: URL!
    private var server: Process?
    private var port = 0

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        port = Int.random(in: 40_000..<60_000)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", folder.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        self.server = server
        // Wait until it answers.
        for _ in 0..<100 {
            if let (_, response) = try? await URLSession.shared.data(from: url("")),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("The local HTTP server didn't start.")
    }

    override func tearDown() {
        server?.terminate()
        server?.waitUntilExit()
        try? FileManager.default.removeItem(at: folder)
    }

    private func url(_ name: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(name)")! }

    private func shell(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }

    /// A Tabula.app with `identifier` and `version`, ad-hoc signed unless `signed` is false, zipped as Tabula.zip,
    /// and a SHA256SUMS listing `checksum` (the archive's own when nil).
    private func release(
        identifier: String,
        version: String,
        signed: Bool = true,
        checksum: String? = nil,
        listed: Bool = true
    ) throws -> AvailableUpdate {
        let build = folder.appendingPathComponent("build-\(UUID().uuidString)")
        let app = build.appendingPathComponent("Tabula.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: macOS.appendingPathComponent("Tabula")
        )
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleExecutable": "Tabula",
            "CFBundlePackageType": "APPL",
        ]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        if signed {
            try shell("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        }
        let archive = folder.appendingPathComponent("Tabula.zip")
        try? FileManager.default.removeItem(at: archive)
        try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, archive.path])
        let digest = try checksum ?? Updater.sha256(of: archive)
        let sums = listed ? "\(digest)  Tabula.zip\n" : "\(digest)  Other.zip\n"
        try sums.write(to: folder.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        return AvailableUpdate(
            version: try XCTUnwrap(SemanticVersion("9.9.9")),
            title: "Tabula 9.9.9",
            notes: "",
            pageURL: url("page"),
            archiveURL: url("Tabula.zip"),
            archiveName: "Tabula.zip",
            archiveSize: size,
            checksumsURL: url("SHA256SUMS")
        )
    }

    private var identifier: String { Bundle.main.bundleIdentifier ?? "app.tabula.Tabula" }

    private func workFolders() throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix(Updater.workPrefix) }
        )
    }

    /// Why the release was refused, checking that the refused download was removed.
    private func failure(_ update: AvailableUpdate) async throws -> String? {
        let before = try workFolders()
        do {
            _ = try await Updater.prepare(update) { _ in }
            return nil
        } catch {
            XCTAssertEqual(try workFolders(), before, "a refused download leaves nothing behind")
            return error.localizedDescription
        }
    }

    func testAGoodReleaseIsAccepted() async throws {
        let update = try release(identifier: identifier, version: "9.9.9")
        let app = try await Updater.prepare(update) { _ in }
        XCTAssertEqual(app.lastPathComponent, "Tabula.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    }

    func testAModifiedDownloadIsRefused() async throws {
        let update = try release(identifier: identifier, version: "9.9.9", checksum: String(repeating: "0", count: 64))
        let message = try await failure(update)
        XCTAssertEqual(
            message,
            "The download is corrupted or was modified (SHA-256 mismatch). Nothing was installed."
        )
    }

    func testAReleaseWithoutAChecksumIsRefused() async throws {
        let update = try release(identifier: identifier, version: "9.9.9", listed: false)
        let message = try await failure(update)
        XCTAssertEqual(message, "The release has no checksum for Tabula.zip.")
    }

    func testAnotherAppOrVersionIsRefused() async throws {
        let other = try release(identifier: "com.example.other", version: "9.9.9")
        let otherMessage = try await failure(other)
        XCTAssertEqual(otherMessage, "The downloaded app isn't Tabula 9.9.9.")
        let older = try release(identifier: identifier, version: "1.0.0")
        let olderMessage = try await failure(older)
        XCTAssertEqual(olderMessage, "The downloaded app isn't Tabula 9.9.9.")
    }

    func testAnUnsignedAppIsRefused() async throws {
        let update = try release(identifier: identifier, version: "9.9.9", signed: false)
        let message = try await failure(update)
        XCTAssertTrue(message?.hasPrefix("codesign failed:") == true, message ?? "accepted")
    }
}
