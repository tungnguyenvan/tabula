import AppKit
import SwiftUI
import TabulaFoundation
import TabulaMongo
import TabulaSQL
import TabulaTransfer

struct StructureView: View {
    let model: TableTabModel

    private static func kindLabel(_ index: IndexInfo) -> String {
        if index.isPrimary {
            return "PRIMARY"
        }
        if index.isUnique {
            return "UNIQUE"
        }
        return "INDEX"
    }

    var body: some View {
        // The columns take extra height. The saved position has a new name: the old one kept the columns at their
        // minimum, a default nobody chose.
        VerticalSplit(
            topMinimum: Layout.Structure.columnsMinHeight,
            bottomMinimum: Layout.Structure.indexesMinHeight,
            bottomIdeal: Layout.Structure.indexesIdealHeight,
            growing: .top,
            autosaveName: "StructureColumns"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    model.driver.kind.isDocument
                        ? "Fields (from the first \(Defaults.Mongo.sampleSize) documents)" : "Columns"
                )
                .font(.headline).padding([.horizontal, .top], 10)
                if model.driver.kind.isDocument {
                    fieldsTable
                } else {
                    columnsTable
                }
            }
        } bottom: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Indexes").font(.headline).padding([.horizontal, .top], 10)
                if let indexesError = model.indexesError {
                    Label("Couldn't read the indexes: \(indexesError)", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                }
                Table(model.indexes) {
                    TableColumn("Name") { Text($0.name).font(.body.monospaced()) }
                    TableColumn(model.driver.kind.isDocument ? "Fields" : "Columns") {
                        Text($0.columns.joined(separator: ", ")).font(.body.monospaced())
                    }
                    TableColumn("Kind") { index in
                        Text(Self.kindLabel(index))
                    }
                    .width(80)
                    TableColumn("Definition") {
                        Text($0.definition ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var columnsTable: some View {
        Table(model.columns) {
            TableColumn("Name") { column in
                HStack(spacing: 4) {
                    if column.isPrimaryKey {
                        Image(systemName: "key.fill").foregroundStyle(.yellow).font(.caption)
                    }
                    Text(column.name).font(.body.monospaced())
                }
            }
            TableColumn("Type") { Text($0.dataType).font(.body.monospaced()) }
            TableColumn("Nullable") {
                Text($0.isNullable ? "YES" : "NO").foregroundStyle($0.isNullable ? .secondary : .primary)
            }
            .width(70)
            TableColumn("Default") { Text($0.defaultValue ?? "—").font(.body.monospaced()).foregroundStyle(.secondary) }
            TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary) }
        }
    }

    /// MongoDB fields have no defaults or comments; the types are what the sample showed.
    private var fieldsTable: some View {
        Table(model.columns) {
            TableColumn("Name") { column in
                HStack(spacing: 4) {
                    if column.isPrimaryKey {
                        Image(systemName: "key.fill").foregroundStyle(.yellow).font(.caption)
                    }
                    Text(column.name).font(.body.monospaced())
                }
            }
            TableColumn("Types seen") { Text($0.dataType).font(.body.monospaced()) }
            TableColumn("Missing in some") {
                Text($0.isNullable ? "YES" : "NO").foregroundStyle($0.isNullable ? .secondary : .primary)
            }
        }
    }
}
