import AppKit
import SwiftUI
import TabulaFoundation
import TabulaMongo
import TabulaSQL
import TabulaTransfer

/// Small borderless icon button used in the bottom bars.
struct BarButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    private var symbolStyle: AnyShapeStyle {
        if active {
            return AnyShapeStyle(Color.accentColor)
        }
        if isEnabled {
            return AnyShapeStyle(.primary)
        }
        return AnyShapeStyle(.tertiary)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .foregroundStyle(symbolStyle)
                .contentShape(Rectangle())
                .help(help)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
    }
}

struct ExportMenu: View {
    let suggestedName: String
    let text: (ExportFormat) throws -> String

    var body: some View {
        Menu {
            Section("Save to file") {
                ForEach(ExportFormat.allCases) { format in
                    Button("\(format.displayName)…") { save(format) }
                }
            }
            Section("Copy to clipboard") {
                ForEach(ExportFormat.allCases) { format in
                    Button("Copy as \(format.displayName)") {
                        do {
                            Clipboard.copy(try text(format))
                        } catch {
                            Confirmation.report("Couldn’t copy the rows as \(format.displayName).", error: error)
                        }
                    }
                }
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up").labelStyle(.iconOnly).font(.system(size: 12))
        }
        .fixedSize()
        .help("Export the rows shown")
    }

    private func save(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text(format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Confirmation.report("Couldn’t export “\(url.lastPathComponent)”.", error: error)
        }
    }
}
