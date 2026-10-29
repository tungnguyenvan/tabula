import AppKit

/// The standard About panel, with credits written in code so they use system colors (an HTML credits
/// file keeps its fixed colors and turns unreadable in Dark Mode).
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var repositoryURL: String? {
        Updater.repository.map { "https://github.com/\($0)" }
    }

    static var credits: NSAttributedString {
        let text = NSMutableAttributedString()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = Layout.About.paragraphSpacing

        func add(_ string: String, color: NSColor = .labelColor, bold: Bool = false, link: String? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: bold
                    ? NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                    : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: color,
                .paragraphStyle: centered,
            ]
            if let link, let url = URL(string: link) {
                attributes[.link] = url
            }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        add("A fast, native client for PostgreSQL, MySQL / MariaDB, SQLite, MongoDB and Redis.\n")
        add(
            "Browse and edit tables and collections, write SQL or MongoDB queries with suggestions, see relationships and server metrics, "
                + "and keep several connections in one window. Optional AI assistant: Apple Intelligence, local models, "
                + "or the API or tool of your choice.\n",
            color: .secondaryLabelColor
        )

        add("Your data\n", bold: true)
        add(
            "Connections are stored on this Mac and passwords in the Keychain. Tabula talks only to your databases, "
                + "to GitHub for updates, and, if you turn it on, to your AI provider, which receives table, collection and "
                + "field names and your queries, plus the results of read-only queries the chat runs if you allow it (Settings › AI). "
                + "No telemetry, no account.\n",
            color: .secondaryLabelColor
        )

        if let repositoryURL {
            add("Website", link: repositoryURL)
            add("  ·  ", color: .tertiaryLabelColor)
            add("Releases", link: repositoryURL + "/releases")
            add("  ·  ", color: .tertiaryLabelColor)
            add("Changelog", link: repositoryURL + "/blob/main/CHANGELOG.md")
            add("  ·  ", color: .tertiaryLabelColor)
            add("Report a problem\n", link: repositoryURL + "/issues")
        }
        add("Keyboard shortcuts: Help › Keyboard Shortcuts (⇧⌘/)\n", color: .secondaryLabelColor)

        add("Made by Nguyen Van Tung. Free, under the MIT License.\n", color: .secondaryLabelColor)
        add(
            "Built with PostgresNIO, MySQLNIO, RediStack, MongoKitten, SwiftNIO, swift-nio-ssl, swift-crypto, SQLite and llama.cpp. "
                + "Their licenses are in THIRD_PARTY_NOTICES.txt inside the app.",
            color: .tertiaryLabelColor
        )
        return text
    }
}
