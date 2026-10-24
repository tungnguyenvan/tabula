import AppKit
import SwiftUI
import TabulaCore

/// The statements a workspace sent to the server, newest last.
@MainActor @Observable
final class QueryLogModel {
    private(set) var entries: [QueryLogEntry] = []
    /// Catalog reads the app makes itself; hidden unless asked for.
    var showMeta = false

    var visible: [QueryLogEntry] { showMeta ? entries : entries.filter { !$0.isMeta } }

    func append(_ entry: QueryLogEntry) {
        entries.append(entry)
        if entries.count > Defaults.consoleLogLimit { entries.removeFirst(entries.count - Defaults.consoleLogLimit) }
    }

    func clear() { entries = [] }

    /// The log as a SQL script with outcomes as comments.
    var text: String {
        visible.map { "-- \(Self.time($0.date)) \(Self.describe($0))\n\($0.statement)\($0.isMeta ? "" : ";")" }.joined(separator: "\n\n")
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    static func describe(_ entry: QueryLogEntry) -> String {
        let duration = Duration.milliseconds(Int(entry.duration * 1000)).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        switch entry.outcome {
        case .rows(let count): return "\(count) row\(count == 1 ? "" : "s") · \(duration)"
        case .affected(let count): return (count.map { "\($0) affected · " } ?? "") + duration
        case .failed(let message): return "failed: \(message)"
        }
    }
}

struct ConsoleLogView: View {
    @Bindable var log: QueryLogModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Layout.barPadding) {
                Text("Console").font(Layout.Font.smallBold)
                Text("\(log.visible.count)").font(Layout.Font.small).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show metadata queries", isOn: $log.showMeta).toggleStyle(.checkbox).font(Layout.Font.small)
                BarButton(symbol: "doc.on.doc", help: "Copy log as SQL") { Clipboard.copy(log.text) }
                BarButton(symbol: "trash", help: "Clear log") { log.clear() }
                BarButton(symbol: "xmark", help: "Hide console (⇧⌘C)", action: close)
            }
            .padding(.horizontal, Layout.barPadding)
            .frame(height: Layout.barHeight)
            .barBackground()
            Divider()
            ScrollViewReader { proxy in
                List(log.visible) { entry in
                    ConsoleLogRow(entry: entry).id(entry.id)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, Layout.Console.rowHeight)
                .onChange(of: log.entries.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .overlay {
                    if log.visible.isEmpty {
                        Text("Statements sent to the server appear here.").font(Layout.Font.small).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct ConsoleLogRow: View {
    let entry: QueryLogEntry

    private var failed: Bool {
        if case .failed = entry.outcome { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Layout.barPadding) {
            Text(QueryLogModel.time(entry.date)).font(Layout.Font.monoSmall).foregroundStyle(.tertiary)
            Text(entry.statement)
                .font(Layout.Font.monoSmall)
                .foregroundStyle(entry.isMeta ? .secondary : .primary)
                .lineLimit(Layout.Console.statementLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(QueryLogModel.describe(entry))
                .font(Layout.Font.small)
                .foregroundStyle(failed ? Color.red : .secondary)
                .lineLimit(1)
                .help(QueryLogModel.describe(entry))
        }
        .contextMenu {
            Button("Copy Statement") { Clipboard.copy(entry.statement) }
        }
    }
}
