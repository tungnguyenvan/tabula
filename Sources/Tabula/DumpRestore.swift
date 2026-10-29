import AppKit
import Observation
import SwiftUI
import TabulaFoundation
import TabulaTransfer

/// A dump or restore in a workspace: its options, then its progress, in one sheet. The work runs in a task the
/// sheet's Cancel stops; the tool is stopped with it.
@MainActor @Observable
final class DatabaseTransfer: Identifiable {
    enum Direction { case dump, restore }
    enum Phase: Equatable {
        case options
        case running
        case finished(String)
        case failed(String)
    }

    let id = UUID()
    let direction: Direction
    let config: ConnectionConfig
    /// The database the window is in (PostgreSQL) or the selected one (MySQL).
    let database: String
    /// Tools found on this Mac, or why none could be used.
    private(set) var tool: DatabaseDump.Located?
    private(set) var toolProblem: String?
    var dumpOptions = DatabaseDump.DumpOptions()
    var restoreOptions = DatabaseDump.RestoreOptions()
    /// Restore: the file chosen, and what it holds.
    private(set) var file: URL?
    private(set) var fileKind: DatabaseDump.FileKind?
    private(set) var fileSize: Int64 = 0
    /// Production restores: the database's name, typed to confirm.
    var typedConfirmation = ""
    private(set) var phase: Phase = .options
    private(set) var progress = DatabaseDump.Progress()
    private(set) var started: Date?
    /// The dump just saved, for Show in Finder.
    private(set) var savedFile: URL?
    private var task: Task<Void, Never>?
    private let password: String?
    private let onRestored: () -> Void

    init(
        direction: Direction,
        config: ConnectionConfig,
        database: String,
        password: String?,
        serverMajor: Int?,
        serverIsMariaDB: Bool,
        tables: [TableRef] = [],
        onRestored: @escaping () -> Void = {}
    ) {
        self.direction = direction
        self.config = config
        self.database = database
        self.password = password
        self.onRestored = onRestored
        dumpOptions.tables = tables
        dumpOptions.serverIsMariaDB = serverIsMariaDB
        restoreOptions.serverMajor = serverMajor
        restoreOptions.serverIsMariaDB = serverIsMariaDB
        // A restore needs its file first: which tools it takes depends on what the file holds.
        if direction == .dump {
            findTool()
        }
    }

    var isPostgres: Bool { config.kind == .postgres }
    var isProduction: Bool { config.tag == .production }

    /// The tools the work runs, the one shown first. Archives restore through psql as well on servers before 17.
    private var neededTools: [DatabaseDump.Tool] {
        switch (direction, config.kind) {
        case (.dump, .postgres): [.pgDump]
        case (.dump, _): [.mysqldump]
        case (.restore, .postgres): postgresRestoreTools
        case (.restore, _): [.mysql]
        }
    }

    private var postgresRestoreTools: [DatabaseDump.Tool] {
        guard fileKind == .postgresArchive else {
            return [.psql]
        }
        if restoreOptions.serverHasTransactionTimeout {
            return [.pgRestore]
        }
        return [.pgRestore, .psql]
    }

    private var toolSearch: Task<Void, Never>?

    private func findTool() {
        toolSearch?.cancel()
        tool = nil
        toolProblem = nil
        let needed = neededTools
        let mariaDB = config.kind == .mysql ? restoreOptions.serverIsMariaDB : nil
        toolSearch = Task { [weak self] in
            var first: DatabaseDump.Located?
            for kind in needed {
                guard let found = await DatabaseDump.locate(kind, preferMariaDB: mariaDB) else {
                    guard !Task.isCancelled else { return }
                    self?.toolProblem = "\(kind.rawValue) isn't installed. \(kind.installHint)"
                    return
                }
                if first == nil {
                    first = found
                }
            }
            guard !Task.isCancelled else { return }
            self?.tool = first
        }
    }

    /// Restore: chooses the dump file. False when the user cancelled.
    func chooseFile() -> Bool {
        let panel = NSOpenPanel()
        panel.message = "Choose a dump to restore into \(database)."
        panel.canChooseDirectories = false
        var chosen: URL?
        #if DEBUG
        // TABULA_DEBUG_RESTORE_FROM: this file without the panel, for scripted checks.
        chosen = ProcessInfo.processInfo.environment["TABULA_DEBUG_RESTORE_FROM"].map { URL(fileURLWithPath: $0) }
        #endif
        if chosen == nil, panel.runModal() == .OK {
            chosen = panel.url
        }
        guard let url = chosen else { return false }
        do {
            fileKind = try DatabaseDump.kind(of: url)
            fileSize = Int64(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0)
            file = url
            findTool()
        } catch {
            Confirmation.report("Couldn’t read “\(url.lastPathComponent)”.", error: error)
            return false
        }
        return true
    }

    var canStart: Bool {
        guard tool != nil, phase == .options, !database.isEmpty else { return false }
        if direction == .restore {
            guard file != nil else { return false }
            if isProduction && typedConfirmation != database {
                return false
            }
            if fileKind == .postgresArchive && !isPostgres {
                return false
            }
        }
        return true
    }

    /// Dump: asks where to save, then starts. Restore: starts.
    func start() {
        guard canStart else { return }
        switch direction {
        case .dump:
            let panel = NSSavePanel()
            let format = isPostgres ? dumpOptions.format : .sql
            let stamp = Date().formatted(.iso8601.year().month().day())
            panel.nameFieldStringValue = "\(database)-\(stamp).\(format.fileExtension)"
            panel.message = "Where to save the dump of \(database)."
            var chosen: URL?
            #if DEBUG
            // TABULA_DEBUG_DUMP_TO: save there without the panel, for scripted checks.
            chosen = ProcessInfo.processInfo.environment["TABULA_DEBUG_DUMP_TO"].map { URL(fileURLWithPath: $0) }
            #endif
            if chosen == nil, panel.runModal() == .OK {
                chosen = panel.url
            }
            guard let url = chosen else { return }
            var options = dumpOptions
            options.format = format
            run { [config, password, database, options] progress in
                try await DatabaseDump.dump(
                    config,
                    password: password,
                    database: database,
                    options: options,
                    to: url,
                    progress: progress
                )
                return "Saved “\(url.lastPathComponent)”."
            } finishing: { [weak self] in
                self?.savedFile = url
            }
        case .restore:
            guard let file else { return }
            let options = restoreOptions
            run { [config, password, database] progress in
                try await DatabaseDump.restore(
                    config,
                    password: password,
                    database: database,
                    options: options,
                    from: file,
                    progress: progress
                )
                return "Restored “\(file.lastPathComponent)” into \(database)."
            } finishing: { [onRestored] in
                onRestored()
            }
        }
    }

    private func run(
        _ work: @escaping @Sendable (@escaping @Sendable (DatabaseDump.Progress) -> Void) async throws -> String,
        finishing: @escaping () -> Void
    ) {
        phase = .running
        started = Date()
        progress = DatabaseDump.Progress(total: direction == .restore && fileKind == .script ? fileSize : nil)
        task = Task { [weak self] in
            do {
                let message = try await work { update in Task { @MainActor in self?.progress = update } }
                self?.phase = .finished(message)
                finishing()
            } catch is CancellationError {
                self?.phase = .failed(
                    self?.direction == .dump
                        ? "Cancelled. No file was saved."
                        : "Cancelled. " + (self?.cancelledRestoreNote ?? "")
                )
            } catch {
                self?.phase = .failed(self?.explain(error) ?? error.localizedDescription)
            }
        }
    }

    /// The tool's message, with what it means for the data and what to try.
    private func explain(_ error: Error) -> String {
        var text = error.localizedDescription
        guard direction == .restore else { return text + "\n\nNo file was saved." }
        if text.contains("already exists") {
            text +=
                isPostgres && fileKind == .postgresArchive
                ? "\n\nThe database already has these objects. Turn on “Drop existing objects first”, or restore into an empty database."
                : "\n\nThe database already has these objects. Restore into an empty database, or dump again with “Drop objects before creating them”."
        }
        if isPostgres && restoreOptions.singleTransaction {
            text += "\n\nNothing was changed: the restore ran in one transaction."
        }
        return text
    }

    private var cancelledRestoreNote: String {
        isPostgres && restoreOptions.singleTransaction
            ? "The restore ran in one transaction, so nothing was changed."
            : "Statements that ran before cancelling stay applied."
    }

    func cancel() {
        toolSearch?.cancel()
        task?.cancel()
    }
    var isRunning: Bool { phase == .running }
}

struct DatabaseTransferSheet: View {
    @Bindable var transfer: DatabaseTransfer
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.Transfer.spacing) {
            Text(title).font(.headline)
            Text(target).font(.callout).foregroundStyle(.secondary)
            switch transfer.phase {
            case .options: options
            case .running: running
            case .finished(let message): outcome(message, symbol: "checkmark.circle.fill", color: .green)
            case .failed(let message): outcome(message, symbol: "xmark.octagon.fill", color: .red)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(Layout.Sheet.padding)
        .frame(width: Layout.Transfer.width)
        .frame(minHeight: Layout.Transfer.minHeight)
        .interactiveDismissDisabled(transfer.isRunning)
    }

    private var title: String {
        transfer.direction == .dump ? "Dump \(transfer.database)" : "Restore into \(transfer.database)"
    }

    private var target: String {
        let ssh = transfer.config.ssh.map { " through \($0.host)" } ?? ""
        return "\(transfer.config.kind.displayName) · \(transfer.config.subtitle)\(ssh)"
    }

    @ViewBuilder
    private var options: some View {
        Form {
            if transfer.direction == .dump {
                dumpOptions
            } else {
                restoreOptions
            }
            Section {
                if let tool = transfer.tool {
                    LabeledContent("Tool") {
                        Text(tool.version).lineLimit(1).truncationMode(.middle).help(tool.path)
                    }
                } else if let problem = transfer.toolProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Tool") { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var dumpOptions: some View {
        Section {
            if transfer.dumpOptions.tables.isEmpty {
                LabeledContent("Tables", value: "All")
            } else {
                LabeledContent("Tables") {
                    Text(transfer.dumpOptions.tables.map(\.name).joined(separator: ", ")).lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Picker("Content", selection: $transfer.dumpOptions.content) {
                ForEach(DatabaseDump.Content.allCases) { Text($0.title).tag($0) }
            }
            if transfer.isPostgres {
                Picker("Format", selection: $transfer.dumpOptions.format) {
                    Text("SQL script (.sql)").tag(DatabaseDump.Format.sql)
                    Text("Custom archive (.dump)").tag(DatabaseDump.Format.custom)
                }
                .help(
                    "A SQL script can be read and run anywhere; the custom archive is compressed and restored with pg_restore."
                )
            }
            Toggle("Drop objects before creating them", isOn: $transfer.dumpOptions.addDrop)
                .help("Restoring the dump then replaces existing tables instead of failing on them.")
                .disabled(
                    transfer.dumpOptions.content == .data
                        || (transfer.isPostgres && transfer.dumpOptions.format == .custom)
                )
            if transfer.isPostgres {
                Toggle("Include owners and privileges", isOn: $transfer.dumpOptions.ownersAndPrivileges)
                    .help("Off: the dump restores under any login, as when copying a database to this Mac.")
            }
        }
    }

    @ViewBuilder
    private var restoreOptions: some View {
        Section {
            if let file = transfer.file {
                LabeledContent("File") {
                    Text(
                        "\(file.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: transfer.fileSize, countStyle: .file))"
                    )
                    .lineLimit(1).truncationMode(.middle).help(file.path)
                }
                LabeledContent(
                    "Kind",
                    value: transfer.fileKind == .postgresArchive
                        ? "PostgreSQL archive (pg_dump custom format)" : "SQL script"
                )
            }
            if transfer.fileKind == .postgresArchive && !transfer.isPostgres {
                Label(
                    "A PostgreSQL archive can't be restored into \(transfer.config.kind.displayName).",
                    systemImage: "xmark.octagon"
                )
                .foregroundStyle(.red)
            }
            if transfer.isPostgres {
                Toggle("All or nothing (one transaction)", isOn: $transfer.restoreOptions.singleTransaction)
                    .help("If a statement fails, everything before it is rolled back.")
                if transfer.fileKind == .postgresArchive {
                    Toggle("Drop existing objects first", isOn: $transfer.restoreOptions.dropExisting)
                    Toggle("Skip owners and privileges", isOn: $transfer.restoreOptions.skipOwnersAndPrivileges)
                }
            }
        } footer: {
            Text(
                "The restore stops at the first error. It changes \(transfer.database) and can replace data in it. Restore only dumps you trust: a dump can contain any SQL."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        if transfer.isProduction {
            Section {
                TextField("Type \(transfer.database) to confirm", text: $transfer.typedConfirmation)
            } header: {
                Label("This is a PRODUCTION connection", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: Layout.Transfer.spacing) {
            if let total = transfer.progress.total, total > 0 {
                ProgressView(value: Double(min(transfer.progress.bytes, total)), total: Double(total))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(status(at: context.date)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            // Until the tool says something, it is still connecting (through SSH, opening the tunnel first).
            Text(
                transfer.progress.message.isEmpty && transfer.progress.bytes == 0
                    ? "Connecting…" : transfer.progress.message
            )
            .font(Layout.Font.monoSmall).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
    }

    private func status(at now: Date) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: transfer.progress.bytes, countStyle: .file)
        let elapsed = Duration.seconds(now.timeIntervalSince(transfer.started ?? now))
            .formatted(.time(pattern: .minuteSecond))
        guard transfer.progress.bytes > 0 else { return elapsed }
        if let total = transfer.progress.total, total > 0 {
            return "\(bytes) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(elapsed)"
        }
        return transfer.direction == .dump ? "\(bytes) written · \(elapsed)" : elapsed
    }

    private func outcome(_ message: String, symbol: String, color: Color) -> some View {
        ScrollView {
            Label {
                Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
        }
        .frame(maxHeight: Layout.Transfer.messageHeight)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Spacer()
            switch transfer.phase {
            case .options:
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button(transfer.direction == .dump ? "Dump…" : "Restore") { transfer.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!transfer.canStart)
            case .running:
                Button("Stop", role: .cancel) { transfer.cancel() }.keyboardShortcut(.cancelAction)
            case .finished, .failed:
                if let file = transfer.savedFile {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
    }
}
