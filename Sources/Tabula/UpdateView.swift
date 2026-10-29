import SwiftUI
import TabulaUpdates

struct UpdateView: View {
    @Bindable var updater: Updater
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppMark(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline)
                    Text("You have version \(Updater.currentVersion.description).").font(.callout).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        // So the next automatic check can open the window again.
        .onDisappear { updater.showWindow = false }
    }

    private var headline: String {
        switch updater.state {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "Tabula is up to date"
        case .available(let update), .downloading(let update, _), .installing(let update): "Tabula \(update.version) is available"
        case .failed: "Couldn't update"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updater.state {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            HStack {
                Spacer()
                Button("OK") { dismissWindow() }.keyboardShortcut(.defaultAction)
            }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let page = Updater.releasesPage {
                    Button("Open Releases Page") { NSWorkspace.shared.open(page) }
                }
                Spacer()
                Button("Close") { dismissWindow() }
                Button("Try Again") { Task { await updater.check(userInitiated: true) } }.keyboardShortcut(.defaultAction)
            }
        case .available(let update):
            notes(update)
            let location = Updater.installLocation()
            if case .failure(let reason) = location {
                Label(reason.localizedDescription, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Skip This Version") { updater.skip(update); dismissWindow() }
                Button("Release Page") { NSWorkspace.shared.open(update.pageURL) }
                Spacer()
                Button("Later") { dismissWindow() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { updater.install(update) }
                    .keyboardShortcut(.defaultAction)
                    .disabled((try? location.get()) == nil)
            }
        case .downloading(let update, let progress):
            notes(update)
            ProgressView(value: progress) {
                Text("Downloading \(RedisFormat.bytes(update.archiveSize))…").font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { updater.cancelDownload() }
            }
        case .installing:
            ProgressView { Text("Verified. Installing and relaunching…").font(.callout) }
        }
    }

    /// Headings become bold lines and list markers become bullets (SwiftUI renders inline Markdown only).
    static func readable(_ markdown: String) -> String {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { return "**" + trimmed.drop(while: { $0 == "#" || $0 == " " }) + "**" }
            if trimmed.hasPrefix("- ") {
                let indent = line.prefix(while: { $0 == " " })
                return indent + (indent.isEmpty ? "• " : "◦ ") + trimmed.dropFirst(2)
            }
            return line
        }.joined(separator: "\n")
    }

    private func notes(_ update: AvailableUpdate) -> some View {
        ScrollView {
            Text((try? AttributedString(markdown: Self.readable(update.notes), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                 ?? AttributedString(Self.readable(update.notes)))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(height: 220)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct SettingsView: View {
    /// Reopens on the tab used last, as macOS settings windows do.
    @AppStorage("TabulaSettingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AISettingsView().tabItem { Label("AI", systemImage: "sparkles") }.tag("ai")
        }
    }
}

private struct GeneralSettingsView: View {
    @State private var automatic = Updater.shared.automaticallyChecks
    @AppStorage(WorkspaceModel.restoresStateKey) private var restoresState = true

    var body: some View {
        Form {
            Section("Connections") {
                Toggle("Reopen tabs when connecting", isOn: $restoresState)
                    // Off forgets what was kept, not only stops keeping it.
                    .onChange(of: restoresState) { _, on in if !on { WorkspaceModel.stateStore.removeAll() } }
                Text("Opening a connection brings back its query tabs (with their SQL), open tables, schema and query history. They are kept on this Mac only. Tabula never reconnects by itself at launch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $automatic)
                    .onChange(of: automatic) { _, value in Updater.shared.automaticallyChecks = value }
                Text("Tabula checks GitHub at most once a day when it starts. It never downloads or installs anything without asking.")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = Updater.shared.lastCheck {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.Settings.width)
        .fixedSize()
    }
}
