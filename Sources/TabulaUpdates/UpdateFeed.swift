import Foundation
import TabulaFoundation

/// Version numbers like 0.2.0 or v1.10.3; pre-release suffixes ("-beta.1") sort before the release.
public struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        components = numbers.map { $0! }
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let a = index < lhs.components.count ? lhs.components[index] : 0
            let b = index < rhs.components.count ? rhs.components[index] : 0
            if a != b {
                return a < b
            }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (a?, b?): return a.compare(b, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// A published release with the assets the updater needs.
public struct AvailableUpdate: Sendable, Equatable {
    public var version: SemanticVersion
    public var title: String
    public var notes: String
    public var pageURL: URL
    public var archiveURL: URL
    public var archiveName: String
    public var archiveSize: Int
    public var checksumsURL: URL
}

public enum UpdateFeed {
    /// The GitHub API endpoint for `owner/name`'s newest published release.
    public static func latestReleaseURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    public static func releasesPageURL(repository: String) -> URL? {
        URL(string: "https://github.com/\(repository)/releases")
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// Parses a GitHub "latest release" response. Returns nil when it isn't newer than `current`,
    /// is a draft or pre-release, or lacks the ZIP and checksum assets.
    public static func update(from data: Data, current: SemanticVersion) throws -> AvailableUpdate? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, let version = SemanticVersion(release.tag_name),
            version.prerelease == nil,
            current < version
        else { return nil }
        let archiveName = "Tabula-\(version).zip"
        guard let archive = release.assets.first(where: { $0.name == archiveName }),
            let sums = release.assets.first(where: { $0.name == "SHA256SUMS.txt" })
        else { return nil }
        return AvailableUpdate(
            version: version,
            title: release.name ?? "Tabula \(version)",
            notes: release.body ?? "",
            pageURL: release.html_url,
            archiveURL: archive.browser_download_url,
            archiveName: archiveName,
            archiveSize: archive.size,
            checksumsURL: sums.browser_download_url
        )
    }

    /// The expected SHA-256 for `file` from `shasum -a 256` output ("<hex>  <name>" per line).
    public static func checksum(for file: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }  // binary-mode marker
            let hex = parts[0].lowercased()
            if name == file, hex.count == 64, hex.allSatisfy(\.isHexDigit) {
                return hex
            }
        }
        return nil
    }

    /// Fetches the feed. GitHub answers 404 when no release has been published yet; that means "no update".
    public static func check(
        feed: URL,
        current: SemanticVersion,
        session: URLSession = .shared
    ) async throws -> AvailableUpdate? {
        var request = URLRequest(
            url: feed,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Defaults.Updates.requestTimeout
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tabula/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            return nil
        }
        if status == 403 || status == 429 {
            throw DatabaseError("GitHub is limiting update checks right now. Try again later.")
        }
        guard status == 200 else {
            throw DatabaseError("Update check failed (HTTP \(status)).")
        }
        return try update(from: data, current: current)
    }
}
