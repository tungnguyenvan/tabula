import AppKit
import SwiftUI
import TabulaRedis

extension RedisKeyType {
    var badge: String {
        switch self {
        case .string: "STR"
        case .hash: "HASH"
        case .list: "LIST"
        case .set: "SET"
        case .zset: "ZSET"
        case .stream: "STRM"
        case .unknown: "?"
        }
    }

    var color: Color {
        switch self {
        case .string: .blue
        case .hash: .purple
        case .list: .green
        case .set: .orange
        case .zset: .pink
        case .stream: .teal
        case .unknown: .gray
        }
    }
}

struct RedisTypeBadge: View {
    let type: RedisKeyType

    var body: some View {
        Text(type.badge)
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .foregroundStyle(type.color)
            .frame(width: 34)
            .padding(.vertical, 2)
            .background(type.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}

enum RedisFormat {
    static func ttl(_ milliseconds: Int?) -> String {
        guard let milliseconds else {
            return "No expiry"
        }
        var seconds = milliseconds / 1000
        if seconds == 0 {
            return "< 1s"
        }
        let days = seconds / 86_400
        seconds %= 86_400
        let hours = seconds / 3600
        seconds %= 3600
        let minutes = seconds / 60
        seconds %= 60
        let parts = [(days, "d"), (hours, "h"), (minutes, "m"), (seconds, "s")].filter { $0.0 > 0 }.prefix(2)
        return parts.map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }
}

/// A Redis connection's detail column and toolbar items, in its window's split view; its sidebar is `RedisSidebar`.
struct RedisWorkspaceView: View {
    @Bindable var model: RedisWorkspaceModel

    var body: some View {
        detail
            .navigationTitle(model.config.displayName)
            .toolbar {
                ConnectionPillItem(
                    pill: ConnectionPill(
                        config: model.config,
                        status: model.status,
                        location: "db\(model.database)",
                        serverVersion: model.driver?.serverDescription,
                        connectedAt: model.connectedAt,
                        onReconnect: { Task { await model.reconnect() } }
                    )
                )
                ToolbarItem(placement: .navigation) {
                    OpenConnectionMenu(current: model.config.id)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(RedisWorkspaceModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Keys / Console (⌘T) / Metrics (⌥⌘4)")
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh (⌘R)")
                    .disabled(model.driver == nil)
                }
            }
            .sheet(isPresented: $model.showNewKey) { NewRedisKeySheet(model: model) }
            .background {
                Button("") {
                    if model.driver != nil {
                        model.mode = .keys
                        model.showNewKey = true
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .hidden()
            }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.status {
        case .connecting:
            ProgressView("Connecting…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Could not connect to \(model.config.displayName)").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled).frame(maxWidth: 480)
                Button("Try Again") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            switch model.mode {
            case .console:
                RedisConsoleView(model: model.console)
            case .metrics:
                if let metrics = model.metrics {
                    MetricsView(model: metrics)
                }
            case .keys:
                RedisKeysPane(model: model)
            }
        }
    }
}

/// Sidebar: the server's databases with their key counts.
struct RedisSidebar: View {
    @Bindable var model: RedisWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if let color = model.config.tag.color {
                Rectangle().fill(color).frame(height: 3)
            }
            List(
                selection: Binding(
                    get: { model.database },
                    set: { index in if let index { Task { await model.selectDatabase(index) } } }
                )
            ) {
                Section {
                    ForEach(model.databases, id: \.index) { db in
                        HStack {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 11))
                                .foregroundStyle(db.keys > 0 ? Color.red : Color.secondary)
                            Text("db\(db.index)").font(.system(size: 12))
                            Spacer()
                            Text(db.keys > 0 ? "\(db.keys)" : "empty")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(db.keys > 0 ? .secondary : .tertiary)
                        }
                        .tag(db.index)
                    }
                } header: {
                    Text("Databases")
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
            Divider()
            HStack(spacing: 6) {
                Text(model.driver?.serverDescription ?? "Redis").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                BarButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)") { Task { await model.refresh() } }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
    }
}

/// Content: the keys table with filters, and the selected key's editor underneath.
private struct RedisKeysPane: View {
    @Bindable var model: RedisWorkspaceModel

    var body: some View {
        VerticalSplit(
            topMinimum: Layout.Redis.keysMinHeight,
            bottomMinimum: Layout.Redis.valueMinHeight,
            topIdeal: Layout.Redis.keysIdealHeight,
            autosaveName: "RedisKeys"
        ) {
            VStack(spacing: 0) {
                RedisFilterBar(model: model)
                Divider()
                if let error = model.keysError {
                    ErrorBanner(message: error) { model.keysError = nil }
                }
                DataGridView(
                    source: GridSource(
                        columns: ["key", "type", "ttl", "size", "value"],
                        rowCount: model.keys.count,
                        version: model.keysVersion,
                        cell: { row, column in cell(row: row, column: column) },
                        isEditable: { row in model.keys.indices.contains(row) },
                        isColumnEditable: { column in column != 1 && column != 3 },
                        copyRows: { rows in
                            rows.filter { model.keys.indices.contains($0) }.map { [model.keys[$0].key.display] }
                        }
                    ),
                    selection: $model.keySelection,
                    onEdit: { row, column, value in
                        guard model.isEditable(row: row, column: column) else {
                            model.keysError = column == 4 ? "Edit long or non-string values in the panel below." : nil
                            NSSound.beep()
                            return
                        }
                        Task { await model.edit(row: row, column: column, value: value) }
                    },
                    onDelete: { rows in
                        model.confirmDelete(rows.filter { model.keys.indices.contains($0) }.map { model.keys[$0].key })
                    }
                )
                .overlay {
                    if model.keys.isEmpty && !model.loadingKeys {
                        Text(
                            model.pattern == "*" && model.typeFilter == nil
                                ? "No keys in db\(model.database)" : "No keys match"
                        )
                        .font(.callout).foregroundStyle(.tertiary)
                    }
                }
                Divider()
                bottomBar
            }
        } bottom: {

            Group {
                if let key = model.keyModel {
                    RedisKeyView(model: key, workspace: model).id(key.key)
                } else {
                    Text(
                        model.keySelection.count > 1
                            ? "\(model.keySelection.count) keys selected" : "Select a key to see and edit its value"
                    )
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func cell(row: Int, column: Int) -> GridCell {
        guard model.keys.indices.contains(row) else { return .null }
        let key = model.keys[row]
        switch column {
        case 0: return .value(key.key.display)
        case 1: return .value(key.type.displayName)
        case 2: return .value(key.ttlMilliseconds == nil ? "∞" : RedisTTL.format(milliseconds: key.ttlMilliseconds))
        case 3:
            if key.type == .string {
                return .value(RedisFormat.bytes(key.length))
            }
            let noun = key.length == 1 ? "item" : "items"
            return .value("\(key.length) \(noun)")
        default: return .value(key.preview)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            BarButton(symbol: "minus", help: "Delete selected keys (⌫)") {
                model.confirmDelete(
                    model.keySelection.filter { model.keys.indices.contains($0) }.map { model.keys[$0].key }
                )
            }
            .disabled(model.keySelection.isEmpty)
            Text("Double-click key, TTL (e.g. 1h 30m, ∞ for none) or a short string value to edit")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            if model.loadingKeys {
                ProgressView().controlSize(.mini)
            }
            let total = model.databases.first(where: { $0.index == model.database })?.keys
            Text("\(model.keys.count) keys" + (total.map { " of \($0)" } ?? ""))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if model.hasMoreKeys {
                Button("Load more") { Task { await model.loadMoreKeys() } }
                    .controlSize(.small)
                    .disabled(model.loadingKeys)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .barBackground()
    }
}

/// The key pattern, type filter and New Key button. Its own view so the pattern field and the focus state that
/// ⌘F sets live in the same hosting view (the split view hosts each pane separately).
private struct RedisFilterBar: View {
    @Bindable var model: RedisWorkspaceModel
    @FocusState private var patternFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Key pattern, e.g. user:*   (⌘F)", text: $model.pattern)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($patternFocused)
                    .onSubmit { Task { await model.reloadKeys() } }
                if model.pattern != "*" {
                    Button {
                        model.pattern = "*"
                        Task { await model.reloadKeys() }
                    } label: {
                        Label("Clear Pattern", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Picker(
                "Type",
                selection: Binding(
                    get: { model.typeFilter },
                    set: { type in
                        model.typeFilter = type
                        Task { await model.reloadKeys() }
                    }
                )
            ) {
                Text("All types").tag(RedisKeyType?.none)
                Divider()
                ForEach(RedisKeyType.allCases.filter { $0 != .unknown }, id: \.self) {
                    Text($0.displayName).tag(RedisKeyType?.some($0))
                }
            }
            .labelsHidden()
            .fixedSize()
            Button {
                model.showNewKey = true
            } label: {
                Label("New Key", systemImage: "plus")
            }
            .help("New key (⌘N)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: model.patternFocusRequest) { _, _ in
            model.mode = .keys
            patternFocused = true
        }
    }
}
