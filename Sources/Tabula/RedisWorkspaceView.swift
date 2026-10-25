import AppKit
import SwiftUI
import TabulaCore

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
        guard let milliseconds else { return "No expiry" }
        var seconds = milliseconds / 1000
        if seconds == 0 { return "< 1s" }
        let days = seconds / 86_400; seconds %= 86_400
        let hours = seconds / 3600; seconds %= 3600
        let minutes = seconds / 60; seconds %= 60
        let parts = [(days, "d"), (hours, "h"), (minutes, "m"), (seconds, "s")].filter { $0.0 > 0 }.prefix(2)
        return parts.map { "\($0.0)\($0.1)" }.joined(separator: " ")
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .memory)
    }
}

struct RedisWorkspaceView: View {
    @Bindable var model: RedisWorkspaceModel

    var body: some View {
        NavigationSplitView {
            RedisSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 320)
        } detail: {
            detail
        }
        .navigationTitle(model.config.displayName)
        .toolbar {
            ConnectionPillItem(pill: ConnectionPill(config: model.config, status: model.status, location: "db\(model.database)",
                                                    serverVersion: model.driver?.serverDescription, connectedAt: model.connectedAt,
                                                    onReconnect: { Task { await model.reconnect() } }))
            ToolbarItem(placement: .navigation) {
                OpenConnectionMenu(current: model.config.id)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(RedisWorkspaceModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Keys / Console (⌘T) / Metrics (⌥⌘4)")
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(model.driver == nil)
            }
        }
        .sheet(isPresented: $model.showNewKey) { NewRedisKeySheet(model: model) }
        .background {
            Button("") { if model.driver != nil { model.mode = .keys; model.showNewKey = true } }
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
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
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
                if let metrics = model.metrics { MetricsView(model: metrics) }
            case .keys:
                RedisKeysPane(model: model)
            }
        }
    }
}

/// Sidebar: the server's databases with their key counts.
private struct RedisSidebar: View {
    @Bindable var model: RedisWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if let color = model.config.tag.color { Rectangle().fill(color).frame(height: 3) }
            List(selection: Binding(
                get: { model.database },
                set: { index in if let index { Task { await model.selectDatabase(index) } } }
            )) {
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
        VerticalSplit(topMinimum: Layout.Redis.keysMinHeight, bottomMinimum: Layout.Redis.valueMinHeight,
                      topIdeal: Layout.Redis.keysIdealHeight, autosaveName: "RedisKeys") {
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
                        copyText: { rows in
                            rows.filter { model.keys.indices.contains($0) }.map { model.keys[$0].key.display }.joined(separator: "\n")
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
                    onDelete: { rows in model.confirmDelete(rows.filter { model.keys.indices.contains($0) }.map { model.keys[$0].key }) }
                )
                .overlay {
                    if model.keys.isEmpty && !model.loadingKeys {
                        Text(model.pattern == "*" && model.typeFilter == nil ? "No keys in db\(model.database)" : "No keys match")
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
                    Text(model.keySelection.count > 1 ? "\(model.keySelection.count) keys selected" : "Select a key to see and edit its value")
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
        case 3: return .value(key.type == .string ? RedisFormat.bytes(key.length) : "\(key.length) item\(key.length == 1 ? "" : "s")")
        default: return .value(key.preview)
        }
    }


    private var bottomBar: some View {
        HStack(spacing: 8) {
            BarButton(symbol: "minus", help: "Delete selected keys (⌫)") {
                model.confirmDelete(model.keySelection.filter { model.keys.indices.contains($0) }.map { model.keys[$0].key })
            }
            .disabled(model.keySelection.isEmpty)
            Text("Double-click key, TTL (e.g. 1h 30m, ∞ for none) or a short string value to edit").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
            if model.loadingKeys { ProgressView().controlSize(.mini) }
            let total = model.databases.first(where: { $0.index == model.database })?.keys
            Text("\(model.keys.count) keys" + (total.map { " of \($0)" } ?? "")).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
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

struct RedisKeyView: View {
    @Bindable var model: RedisKeyModel
    let workspace: RedisWorkspaceModel
    @State private var selection = IndexSet()
    @State private var showTTL = false
    @State private var showRename = false
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error {
                ErrorBanner(message: error) { model.error = nil }
            }
            if model.type == .string {
                stringEditor
            } else if model.type != .unknown {
                DataGridView(
                    source: GridSource(
                        columns: model.columns,
                        rowCount: model.rows.count,
                        version: model.version,
                        cell: { row, column in
                            guard model.rows.indices.contains(row), model.rows[row].indices.contains(column) else { return .null }
                            return .value(model.rows[row][column].display)
                        },
                        isEditable: { row in model.canEditCells && model.rows.indices.contains(row) },
                        copyText: { model.copyText($0) }
                    ),
                    selection: $selection,
                    onEdit: model.canEditCells ? { row, column, value in Task { await model.update(row: row, column: column, to: value) } } : nil,
                    onDelete: { rows in confirmRemove(rows) }
                )
                Divider()
                collectionBar
            } else if model.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .sheet(isPresented: $showTTL) { TTLSheet(model: model) }
        .sheet(isPresented: $showAdd) { AddElementSheet(type: model.type, columns: model.columns) { values in Task { await model.add(values) } } }
        .alert("Rename key", isPresented: $showRename) {
            RenameField(initial: model.key.display) { name in Task { await model.rename(to: name) } }
        } message: {
            Text("Fails if a key with the new name already exists.")
        }
        .background {
            Button("") { Task { await model.saveString() } }.keyboardShortcut("s", modifiers: .command).hidden()
            Button("") { if model.type != .string && model.type != .unknown { showAdd = true } }.keyboardShortcut("i", modifiers: .command).hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RedisTypeBadge(type: model.type)
            Text(model.key.display).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Button { showRename = true } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Rename")
            Spacer()
            if let info = model.info {
                Group {
                    Label(info.type == .string ? RedisFormat.bytes(info.length) : "\(info.length) items", systemImage: "number")
                    if let memory = info.memoryBytes { Label(RedisFormat.bytes(memory), systemImage: "memorychip") }
                    if let encoding = info.encoding { Text(encoding).foregroundStyle(.tertiary) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Button { showTTL = true } label: {
                    Label(RedisFormat.ttl(info.ttlMilliseconds), systemImage: "clock")
                        .foregroundStyle(info.ttlMilliseconds == nil ? .secondary : Color.orange)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Set expiry (TTL)")
            }
            if model.loading { ProgressView().controlSize(.mini) }
            BarButton(symbol: "arrow.clockwise", help: "Reload key") { Task { await model.reload() } }
            BarButton(symbol: "trash", help: "Delete key") { workspace.confirmDelete([model.key]) }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private var stringEditor: some View {
        VStack(spacing: 0) {
            if model.canEditString {
                TextEditor(text: $model.draft)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
            } else {
                ScrollView {
                    Text(model.draft).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            HStack(spacing: 8) {
                if model.stringTruncated {
                    Label("Showing the first \(RedisFormat.bytes(RedisDriver.maxEditableStringBytes)) — read-only", systemImage: "scissors")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                } else if model.stringValue?.isText == false {
                    Label("Binary value — shown escaped, read-only", systemImage: "01.square").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.canEditString {
                    Button("Format JSON") { model.formatJSON() }
                    Button("Revert") { model.draft = model.stringValue?.text ?? "" }.disabled(!model.hasStringChanges)
                    Button("Save") { Task { await model.saveString() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasStringChanges)
                        .help("Save (⌘S). The key's TTL is kept.")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .barBackground()
        }
    }

    private var collectionBar: some View {
        HStack(spacing: 6) {
            BarButton(symbol: "plus", help: "Add (⌘I)") { showAdd = true }
                .disabled(model.type == .unknown)
            BarButton(symbol: "minus", help: "Delete selected (⌫)") { confirmRemove(selection) }
                .disabled(selection.isEmpty)
            if model.type == .stream {
                Text("Stream entries are append-only").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                Text("Double-click a cell to edit · changes save immediately").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(model.rows.count) of \(model.info?.length ?? model.rows.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            if model.next != nil {
                Button("Load more") { Task { await model.loadMore() } }.controlSize(.small).disabled(model.loading)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .barBackground()
    }

    private func confirmRemove(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        if Confirmation.ask(rows.count == 1 ? "Delete this element?" : "Delete \(rows.count) elements?",
                            detail: "The change is saved to Redis immediately.", action: "Delete", style: .informational) {
            selection = []
            Task { await model.remove(rows: rows) }
        }
    }
}

private struct RenameField: View {
    @State var text: String
    let onRename: (String) -> Void

    init(initial: String, onRename: @escaping (String) -> Void) {
        _text = State(initialValue: initial)
        self.onRename = onRename
    }

    var body: some View {
        TextField("New name", text: $text)
        Button("Rename") { onRename(text) }
        Button("Cancel", role: .cancel) {}
    }
}

private struct TTLSheet: View {
    let model: RedisKeyModel
    @Environment(\.dismiss) private var dismiss
    @State private var seconds = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Expiry for “\(model.key.display)”").font(.headline)
            Text("Currently: \(RedisFormat.ttl(model.info?.ttlMilliseconds))").foregroundStyle(.secondary)
            HStack {
                TextField("Seconds", text: $seconds).frame(width: 140)
                Text("seconds")
                Menu("Presets") {
                    ForEach([("1 minute", 60), ("1 hour", 3600), ("1 day", 86_400), ("7 days", 604_800), ("30 days", 2_592_000)], id: \.1) { preset in
                        Button(preset.0) { seconds = String(preset.1) }
                    }
                }
                .fixedSize()
            }
            HStack {
                Button("Remove Expiry") { Task { await model.setTTL(seconds: nil) }; dismiss() }
                    .disabled(model.info?.ttlMilliseconds == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") { Task { await model.setTTL(seconds: Int(seconds)) }; dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled((Int(seconds) ?? 0) <= 0)
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { seconds = model.info?.ttlMilliseconds.map { String(max(1, $0 / 1000)) } ?? "" }
    }
}

/// Values for a new element: hash field+value, list value, set member, zset member+score, stream field=value lines.
private struct AddElementSheet: View {
    let type: RedisKeyType
    let columns: [String]
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to \(type.displayName)").font(.headline)
            ElementFields(type: type, first: $first, second: $second)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { onAdd(ElementFields.values(type: type, first: first, second: second)); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ElementFields.isValid(type: type, first: first, second: second))
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

struct ElementFields: View {
    let type: RedisKeyType
    @Binding var first: String
    @Binding var second: String

    var body: some View {
        Form {
            switch type {
            case .string:
                TextField("Value", text: $first, axis: .vertical).lineLimit(3...10)
            case .hash:
                TextField("Field", text: $first)
                TextField("Value", text: $second, axis: .vertical).lineLimit(1...6)
            case .list:
                TextField("Value (appended)", text: $first, axis: .vertical).lineLimit(1...6)
            case .set:
                TextField("Member", text: $first)
            case .zset:
                TextField("Member", text: $first)
                TextField("Score", text: $second)
            case .stream:
                TextField("Fields, one per line: field=value", text: $first, axis: .vertical).lineLimit(3...8)
            case .unknown:
                EmptyView()
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    static func values(type: RedisKeyType, first: String, second: String) -> [String] {
        switch type {
        case .hash, .zset: return [first, second]
        case .stream:
            return first.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return [] }
                return [parts[0].trimmingCharacters(in: .whitespaces), String(parts[1])]
            }
        default: return [first]
        }
    }

    static func isValid(type: RedisKeyType, first: String, second: String) -> Bool {
        switch type {
        case .string, .list: return true
        case .set: return !first.isEmpty
        case .hash: return !first.isEmpty
        case .zset: return !first.isEmpty && Double(second) != nil
        case .stream: return !values(type: type, first: first, second: second).isEmpty
        case .unknown: return false
        }
    }
}

private struct NewRedisKeySheet: View {
    let model: RedisWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type: RedisKeyType = .string
    @State private var first = ""
    @State private var second = ""
    @State private var ttl = ""
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New key in db\(model.database)").font(.headline)
            Form {
                TextField("Name", text: $name).font(.system(size: 12, design: .monospaced))
                Picker("Type", selection: $type) {
                    ForEach(RedisKeyType.allCases.filter { $0 != .unknown }, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Expiry (seconds, optional)", text: $ttl)
            }
            ElementFields(type: type, first: $first, second: $second)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || name.isEmpty || !ElementFields.isValid(type: type, first: first, second: second) || (!ttl.isEmpty && (Int(ttl) ?? 0) <= 0))
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            try await model.create(key: RedisBytes(name), type: type, values: ElementFields.values(type: type, first: first, second: second).map(RedisBytes.init),
                                   ttl: ttl.isEmpty ? nil : Int(ttl))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RedisConsoleView: View {
    @Bindable var model: RedisConsoleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Text("Type Redis commands as in redis-cli. ↑↓ history · “clear” clears · SUBSCRIBE/MONITOR are not supported.")
                            .foregroundStyle(.tertiary)
                        ForEach(model.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.prompt) ").foregroundStyle(.secondary) + Text(entry.command).bold()
                                Text(entry.output).foregroundStyle(entry.isError ? .red : .primary).textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: model.entries.count) { _, _ in
                    if let last = model.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 6) {
                Text(model.prompt).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                TextField("command", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { Task { await model.run(); focused = true } }
                    .onKeyPress(.upArrow) { model.historyUp(); return .handled }
                    .onKeyPress(.downArrow) { model.historyDown(); return .handled }
                if model.running { ProgressView().controlSize(.mini) }
                BarButton(symbol: "trash", help: "Clear output") { model.clear() }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .barBackground()
        }
        .onAppear { focused = true }
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
                    Button { model.pattern = "*"; Task { await model.reloadKeys() } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Picker("Type", selection: Binding(get: { model.typeFilter }, set: { type in
                model.typeFilter = type
                Task { await model.reloadKeys() }
            })) {
                Text("All types").tag(RedisKeyType?.none)
                Divider()
                ForEach(RedisKeyType.allCases.filter { $0 != .unknown }, id: \.self) { Text($0.displayName).tag(RedisKeyType?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Button { model.showNewKey = true } label: { Label("New Key", systemImage: "plus") }
                .help("New key (⌘N)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onChange(of: model.patternFocusRequest) { _, _ in model.mode = .keys; patternFocused = true }
    }
}
