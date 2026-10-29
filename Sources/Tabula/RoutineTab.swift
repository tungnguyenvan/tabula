import AppKit
import SwiftUI
import TabulaDrivers

/// A function, procedure or trigger opened for viewing and editing (or a new one being written).
@MainActor @Observable
final class RoutineTabModel {
    let id = UUID()
    let driver: any DatabaseDriver
    private(set) var routine: RoutineInfo?
    let newKind: RoutineInfo.Kind
    var text = ""
    /// The definition as the server has it; nil for a routine not created yet.
    private(set) var original: String?
    private(set) var loading = false
    private(set) var saving = false
    var error: String?
    var notice: String?
    let undoManager = UndoManager()
    private weak var workspace: WorkspaceModel?

    init(routine: RoutineInfo, driver: any DatabaseDriver, workspace: WorkspaceModel) {
        self.routine = routine
        self.newKind = routine.kind
        self.driver = driver
        self.workspace = workspace
    }

    /// A new routine, starting from a template.
    init(newKind: RoutineInfo.Kind, template: String, driver: any DatabaseDriver, workspace: WorkspaceModel) {
        self.newKind = newKind
        self.text = template
        self.driver = driver
        self.workspace = workspace
    }

    var title: String { routine?.displayName ?? "New \(newKind.displayName.lowercased())" }
    var hasChanges: Bool { text != (original ?? "") }

    func load() async {
        guard let routine else { return }
        loading = true
        defer { loading = false }
        do {
            let definition = try await driver.definition(of: routine)
            original = definition
            text = definition
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Runs the edited definition (creating, or replacing the routine) and reloads what the server now has.
    func save() async {
        guard !saving, hasChanges, let workspace else { return }
        if workspace.config.tag == .production,
            !Confirmation.ask(
                "Save \(title) on a PRODUCTION connection?",
                detail: "The new definition takes effect immediately.",
                action: "Save"
            )
        {
            return
        }
        saving = true
        defer { saving = false }
        do {
            if let routine, let original {
                try await driver.replace(routine, original: original, with: text)
            } else {
                _ = try await driver.execute(text)
            }
            error = nil
            await workspace.loadRoutines()
            // Re-read the saved routine; a new one is found by matching the name it was created with.
            if routine == nil {
                routine = workspace.routines.first {
                    text.localizedCaseInsensitiveContains($0.name) && $0.kind == newKind
                }
            }
            notice = "Saved."
            if routine != nil {
                await load()
            } else {
                original = text
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revert() {
        text = original ?? text
        error = nil
    }

    func delete() async -> Bool {
        guard let routine, let workspace else { return false }
        let detail =
            workspace.config.tag == .production
            ? "This is a PRODUCTION connection. This cannot be undone." : "This cannot be undone."
        guard
            Confirmation.ask(
                "Delete \(routine.kind.displayName.lowercased()) “\(routine.displayName)”?",
                detail: detail,
                action: "Delete"
            )
        else {
            return false
        }
        guard let routines = driver.routineCatalog else { return false }
        do {
            _ = try await driver.execute(routines.dropStatement(for: routine))
            await workspace.loadRoutines()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct RoutineTabView: View {
    @Bindable var model: RoutineTabModel
    let workspace: WorkspaceModel
    @State private var handle = EditorHandle()

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if let error = model.error {
                ErrorBanner(message: error) { model.error = nil }
            }
            SQLEditorView(
                text: $model.text,
                handle: handle,
                dialect: model.driver.dialect,
                suggest: { _, caret in (NSRange(location: caret, length: 0), []) },
                undoManager: model.undoManager
            ) { _ in Task { await model.save() } }
            .overlay { if model.loading { ProgressView().controlSize(.small) } }
        }
        .task { if model.original == nil, model.routine != nil { await model.load() } }
    }

    private var bar: some View {
        HStack(spacing: Layout.barPadding) {
            Label(
                model.routine?.kind.displayName ?? model.newKind.displayName,
                systemImage: RoutineRow.symbol(model.routine?.kind ?? model.newKind)
            )
            .font(Layout.Font.smallBold)
            if let detail = model.routine?.detail, !detail.isEmpty {
                Text(detail).font(Layout.Font.small).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let notice = model.notice, !model.hasChanges {
                Text(notice).font(Layout.Font.small).foregroundStyle(.secondary)
            }
            if model.saving {
                ProgressView().controlSize(.small)
            }
            Button("Revert") { model.revert() }
                .disabled(!model.hasChanges || model.original == nil)
            Button(model.routine == nil ? "Create" : "Save") { Task { await model.save() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasChanges || model.saving)
                .help("Run the definition on the server (⌘S)")
            if model.routine != nil {
                Button(role: .destructive) {
                    Task { if await model.delete() { workspace.close(model.id) } }
                } label: {
                    Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                }
                .help("Delete")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Layout.barPadding)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Layout.barHeight)
        .barBackground()
    }
}

/// A routine in the sidebar.
struct RoutineRow: View {
    let routine: RoutineInfo

    static func symbol(_ kind: RoutineInfo.Kind) -> String {
        switch kind {
        case .function: "function"
        case .procedure: "gearshape.2"
        case .trigger: "bolt"
        }
    }

    var body: some View {
        Label {
            Text(routine.displayName).font(Layout.Font.body).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: Self.symbol(routine.kind)).font(Layout.Font.small)
                .foregroundStyle(routine.kind == .trigger ? Color.orange : Color.green)
        }
        .help(routine.detail)
    }
}
