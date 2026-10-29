import AppKit
import SwiftUI
import TabulaFoundation

/// Right-hand panel listing every field of the selected row; editable for table tabs.
struct RowInspectorView: View {
    let model: WorkspaceModel

    var body: some View {
        Group {
            if let table = model.selectedTableTab, table.mode == .data {
                if let row = model.inspectedRows.first, row < table.displayRowCount {
                    TableRowInspector(table: table, row: row, count: model.inspectedRows.count)
                } else {
                    placeholder("Select a row to see its fields")
                }
            } else if case .query(let query) = model.selectedTab, let result = query.currentResult, result.hasResultSet
            {
                if let row = model.inspectedRows.first, row < result.rows.count {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(result.columns.enumerated()), id: \.offset) { index, name in
                                let editor = query.resultEditor
                                let info = editor?.target.columns[safe: index]
                                FieldView(
                                    name: name,
                                    type: info?.typeName,
                                    isKey: info?.isKey ?? false,
                                    cell: Self.cell(result, editor: editor, row: row, column: index),
                                    edited: editor?.state(row: row, column: index) == .edited,
                                    editable: editor?.isEditable(row: row, column: index) == true
                                ) { value in
                                    editor?.setValue(value, row: row, column: index)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .id("query-\(query.id)-\(query.selectedResult)-\(row)-\(query.resultEditor?.version ?? 0)")
                } else {
                    placeholder("Select a row to see its fields")
                }
            } else {
                placeholder("No row selected")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The value shown for a result cell: the pending edit when there is one, otherwise what the query returned.
    private static func cell(_ result: QueryResult, editor: QueryResultEditor?, row: Int, column: Int) -> GridCell {
        let value: String?
        if let editor {
            value = editor.value(row: row, column: column)
        } else {
            value = result.rows[row][column]
        }
        guard let value else {
            return .null
        }
        return .value(value)
    }
}

private struct TableRowInspector: View {
    let table: TableTabModel
    let row: Int
    let count: Int

    var body: some View {
        // The parent checks the row too, but after a commit or reload this view can be updated once more with the
        // row it showed before, which may no longer exist (a new row that was saved).
        if row < table.displayRowCount {
            fields
        } else {
            Text("Select a row to see its fields")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var fields: some View {
        VStack(spacing: 0) {
            HStack {
                Text(row >= table.rows.count ? "New row" : "Row \(row + 1 + table.offset)")
                    .font(.system(size: 12, weight: .semibold))
                if count > 1 {
                    Text("(\(count) selected)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(table.resultColumns.enumerated()), id: \.offset) { index, name in
                        // SwiftUI can update these fields before the check above, with a row that just went away.
                        if row < table.displayRowCount {
                            let info = table.columnInfo(name)
                            FieldView(
                                name: name,
                                type: info?.dataType,
                                isKey: info?.isPrimaryKey ?? false,
                                cell: table.cell(row: row, column: index),
                                edited: table.state(row: row, column: index) == .edited,
                                editable: table.isEditable(row: row)
                            ) { value in
                                table.setValue(value, row: row, column: index)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .id("\(table.id)-\(row)-\(table.version)")
        }
    }
}

private struct FieldView: View {
    let name: String
    let type: String?
    let isKey: Bool
    let cell: GridCell
    var edited = false
    let editable: Bool
    let onChange: (String?) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var isNull: Bool { cell == .null }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if isKey {
                    Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                }
                Text(name).font(.system(size: 11, weight: .semibold))
                if let type {
                    Text(type).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
                Spacer()
                if editable {
                    Menu {
                        Button("Set NULL") {
                            text = ""
                            onChange(nil)
                        }
                        Button("Set Empty String") {
                            text = ""
                            onChange("")
                        }
                    } label: {
                        Image(systemName: "ellipsis").help("Set NULL or an empty string")
                    }
                    .help("Set NULL or an empty string")
                    .accessibilityLabel("Set value for \(name)")
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            Group {
                if editable {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                } else {
                    Text(displayText).foregroundStyle(isNull ? .tertiary : .primary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(edited ? Color.yellow.opacity(0.8) : .clear))
        }
        .onAppear { text = currentText }
    }

    private var currentText: String {
        if case .value(let value) = cell {
            return value
        }
        return ""
    }

    private var displayText: String {
        switch cell {
        case .value(let value): value
        case .null: "NULL"
        case .defaultValue: "DEFAULT"
        }
    }

    private var placeholder: String {
        switch cell {
        case .null: "NULL"
        case .defaultValue: "DEFAULT"
        case .value: ""
        }
    }

    private func commit() {
        guard text != currentText else { return }
        onChange(text)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
