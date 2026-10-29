import AppKit
import SwiftUI
import TabulaRedis

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
                            guard model.rows.indices.contains(row), model.rows[row].indices.contains(column) else {
                                return .null
                            }
                            return .value(model.rows[row][column].display)
                        },
                        isEditable: { row in model.canEditCells && model.rows.indices.contains(row) },
                        copyText: { model.copyText($0) }
                    ),
                    selection: $selection,
                    onEdit: model.canEditCells
                        ? { row, column, value in Task { await model.update(row: row, column: column, to: value) } }
                        : nil,
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
        .sheet(isPresented: $showAdd) {
            AddElementSheet(type: model.type, columns: model.columns) { values in Task { await model.add(values) } }
        }
        .alert("Rename key", isPresented: $showRename) {
            RenameField(initial: model.key.display) { name in Task { await model.rename(to: name) } }
        } message: {
            Text("Fails if a key with the new name already exists.")
        }
        .background {
            Button("") { Task { await model.saveString() } }.keyboardShortcut("s", modifiers: .command).hidden()
            Button("") { if model.type != .string && model.type != .unknown { showAdd = true } }
                .keyboardShortcut("i", modifiers: .command).hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RedisTypeBadge(type: model.type)
            Text(model.key.display).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                showRename = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless).help("Rename")
            Spacer()
            if let info = model.info {
                Group {
                    Label(
                        info.type == .string ? RedisFormat.bytes(info.length) : "\(info.length) items",
                        systemImage: "number"
                    )
                    if let memory = info.memoryBytes {
                        Label(RedisFormat.bytes(memory), systemImage: "memorychip")
                    }
                    if let encoding = info.encoding {
                        Text(encoding).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    showTTL = true
                } label: {
                    Label(RedisFormat.ttl(info.ttlMilliseconds), systemImage: "clock")
                        .foregroundStyle(info.ttlMilliseconds == nil ? .secondary : Color.orange)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Set expiry (TTL)")
            }
            if model.loading {
                ProgressView().controlSize(.mini)
            }
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
                    Label(
                        "Showing the first \(RedisFormat.bytes(RedisDriver.maxEditableStringBytes)) — read-only",
                        systemImage: "scissors"
                    )
                    .font(.system(size: 11)).foregroundStyle(.orange)
                } else if model.stringValue?.isText == false {
                    Label("Binary value — shown escaped, read-only", systemImage: "01.square").font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                Text("Double-click a cell to edit · changes save immediately").font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(model.rows.count) of \(model.info?.length ?? model.rows.count)")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
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
        if Confirmation.ask(
            rows.count == 1 ? "Delete this element?" : "Delete \(rows.count) elements?",
            detail: "The change is saved to Redis immediately.",
            action: "Delete",
            style: .informational
        ) {
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
                    ForEach(
                        [
                            ("1 minute", 60), ("1 hour", 3600), ("1 day", 86_400), ("7 days", 604_800),
                            ("30 days", 2_592_000),
                        ],
                        id: \.1
                    ) { preset in
                        Button(preset.0) { seconds = String(preset.1) }
                    }
                }
                .fixedSize()
            }
            HStack {
                Button("Remove Expiry") {
                    Task { await model.setTTL(seconds: nil) }
                    dismiss()
                }
                .disabled(model.info?.ttlMilliseconds == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") {
                    Task { await model.setTTL(seconds: Int(seconds)) }
                    dismiss()
                }
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
                Button("Add") {
                    onAdd(ElementFields.values(type: type, first: first, second: second))
                    dismiss()
                }
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
            return first.split(whereSeparator: \.isNewline)
                .flatMap { line -> [String] in
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

struct NewRedisKeySheet: View {
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
                    ForEach(RedisKeyType.allCases.filter { $0 != .unknown }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                TextField("Expiry (seconds, optional)", text: $ttl)
            }
            ElementFields(type: type, first: $first, second: $second)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        creating || name.isEmpty || !ElementFields.isValid(type: type, first: first, second: second)
                            || (!ttl.isEmpty && (Int(ttl) ?? 0) <= 0)
                    )
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            try await model.create(
                key: RedisBytes(name),
                type: type,
                values: ElementFields.values(type: type, first: first, second: second).map(RedisBytes.init),
                ttl: ttl.isEmpty ? nil : Int(ttl)
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
