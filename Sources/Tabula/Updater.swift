import AppKit
import CryptoKit
import Foundation
import Observation
import TabulaFoundation
import TabulaUpdates

/// Checks GitHub releases, downloads the ZIP, verifies it and replaces the running app.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, progress: Double)
        case installing(AvailableUpdate)
        case failed(String)
    }

    private(set) var state: State = .idle
    var showWindow = false
    private var downloadTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private static let autoCheckKey = "TabulaAutomaticallyCheckForUpdates"
    private static let lastCheckKey = "TabulaLastUpdateCheck"
    private static let skippedKey = "TabulaSkippedVersion"

    var automaticallyChecks: Bool {
        get { defaults.object(forKey: Self.autoCheckKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoCheckKey) }
    }

    var lastCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    static var currentVersion: SemanticVersion {
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return SemanticVersion(text) ?? SemanticVersion("0.0.0")!
    }

    /// `owner/name` of the GitHub repository that publishes releases, written into Info.plist by the build script.
    static var repository: String? {
        Bundle.main.object(forInfoDictionaryKey: "TabulaRepository") as? String
    }

    static var releasesPage: URL? { repository.flatMap(UpdateFeed.releasesPageURL) }

    private var feedURL: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["TABULA_UPDATE_FEED"], let url = URL(string: override) {
            return url
        }
        #endif
        return Self.repository.flatMap(UpdateFeed.latestReleaseURL)
    }

    /// At launch: check at most once a day, silently, and only show the window when there is something new.
    func checkInBackgroundIfDue() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TABULA_UPDATE_FEED"] != nil {
            Task { await check(userInitiated: false) }
            return
        }
        #endif
        guard automaticallyChecks, Bundle.main.bundleURL.pathExtension == "app" else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Defaults.Updates.checkInterval {
            return
        }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = state {
            showWindow = true
            return
        }
        state = .checking
        if userInitiated {
            showWindow = true
        }
        do {
            guard let feedURL else {
                throw DatabaseError("This build doesn't say where its releases are published.")
            }
            let update = try await UpdateFeed.check(feed: feedURL, current: Self.currentVersion)
            defaults.set(Date(), forKey: Self.lastCheckKey)
            if let update, userInitiated || update.version.description != defaults.string(forKey: Self.skippedKey) {
                state = .available(update)
                showWindow = true
                #if DEBUG
                if ProcessInfo.processInfo.environment["TABULA_DEBUG_AUTOINSTALL"] != nil { install(update) }
                #endif
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
            if !userInitiated {
                showWindow = false
            }
        }
    }

    func skip(_ update: AvailableUpdate) {
        defaults.set(update.version.description, forKey: Self.skippedKey)
        state = .idle
        showWindow = false
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading(let update, _) = state {
            state = .available(update)
        }
    }

    // MARK: Install

    /// Where the running app lives, or why it can't be replaced in place.
    static func installLocation() -> Result<URL, InstallError> {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard bundle.pathExtension == "app" else {
            return .failure(.notABundle)
        }
        if bundle.path.contains("/AppTranslocation/") { return .failure(.translocated) }
        if bundle.path.hasPrefix("/Volumes/") {
            // Unknown: the check for a writable location below decides.
            let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
            if values?.volumeIsReadOnly == true {
                return .failure(.readOnlyVolume)
            }
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path),
            FileManager.default.isWritableFile(atPath: bundle.path)
        else { return .failure(.notWritable(bundle.deletingLastPathComponent().path)) }
        return .success(bundle)
    }

    enum InstallError: LocalizedError, Equatable {
        case notABundle, translocated, readOnlyVolume
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .notABundle: "Tabula isn't running from an app bundle, so it can't update itself."
            case .translocated:
                "macOS is running Tabula from a temporary location. Move Tabula to Applications, open it from there and try again."
            case .readOnlyVolume:
                "Tabula is running from the disk image. Drag it to Applications, open it from there and try again."
            case .notWritable(let folder):
                "Tabula can't replace itself because “\(folder)” isn't writable by your account."
            }
        }
    }

    func install(_ update: AvailableUpdate) {
        downloadTask?.cancel()
        state = .downloading(update, progress: 0)
        downloadTask = Task { [weak self] in
            do {
                let target = try Self.installLocation().get()
                let newApp = try await Self.prepare(update) { progress in
                    Task { @MainActor in
                        if case .downloading = self?.state {
                            self?.state = .downloading(update, progress: progress)
                        }
                    }
                }
                try Task.checkCancellation()
                self?.state = .installing(update)
                try Self.replaceAndRelaunch(target: target, with: newApp)
            } catch is CancellationError {
                return
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    /// The folder each update is downloaded and checked in, inside the temporary directory.
    nonisolated static let workPrefix = "TabulaUpdate-"

    /// Downloads and verifies the release; returns the extracted Tabula.app. A release that fails a check (or a
    /// cancelled download) leaves nothing behind; the folder of one that passes goes with the relaunch.
    nonisolated static func prepare(
        _ update: AvailableUpdate,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            workPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            return try await prepare(update, in: work, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    nonisolated private static func prepare(
        _ update: AvailableUpdate,
        in work: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {

        let (sumsData, sumsResponse) = try await URLSession.shared.data(from: update.checksumsURL)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200, let sums = String(data: sumsData, encoding: .utf8),
            let expected = UpdateFeed.checksum(for: update.archiveName, in: sums)
        else {
            throw DatabaseError("The release has no checksum for \(update.archiveName).")
        }

        let archive = work.appendingPathComponent(update.archiveName)
        try await download(update.archiveURL, to: archive, expectedSize: update.archiveSize, progress: progress)

        let digest = try sha256(of: archive)
        guard digest == expected else {
            throw DatabaseError("The download is corrupted or was modified (SHA-256 mismatch). Nothing was installed.")
        }

        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let app = extracted.appendingPathComponent("Tabula.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier ?? "app.tabula.Tabula",
            (info["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init) == update.version
        else {
            throw DatabaseError("The downloaded app isn't Tabula \(update.version).")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    nonisolated private static func download(
        _ url: URL,
        to destination: URL,
        expectedSize: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DatabaseError("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let total = max(Int(response.expectedContentLength), expectedSize, 1)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var received = 0
        var reported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                received += buffer.count
                buffer.removeAll(keepingCapacity: true)
                // Report whole steps only, so the UI isn't flooded with one update per chunk.
                let fraction = min(1, Double(received) / Double(total))
                if fraction - reported >= Defaults.Updates.progressStep {
                    reported = fraction
                    progress(fraction)
                }
                try Task.checkCancellation()
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Drain stderr before waiting: a tool that fills the pipe would otherwise block forever.
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output, encoding: .utf8) ?? ""
            throw DatabaseError(
                "\((tool as NSString).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    /// Hands off to a small shell script that waits for this process to exit, swaps the bundles
    /// (restoring the old one if the copy fails) and opens the new version.
    private static func replaceAndRelaunch(target: URL, with newApp: URL) throws {
        let script = """
            pid="$1"; target="$2"; new="$3"; work="$4"
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            backup="$target.previous-$$"
            if mv "$target" "$backup"; then
              if ditto "$new" "$target"; then
                rm -rf "$backup"
              else
                rm -rf "$target"; mv "$backup" "$target"
              fi
            fi
            rm -rf "$work"
            open "$target"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "tabula-update", String(ProcessInfo.processInfo.processIdentifier), target.path, newApp.path,
            newApp.deletingLastPathComponent().deletingLastPathComponent().path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }
}
