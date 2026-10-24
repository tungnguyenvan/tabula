import AppKit
import SwiftUI
import TabulaCore

struct ConnectionFormView: View {
    @State var config: ConnectionConfig
    let isNew: Bool
    @State var password: String
    let onSave: (ConnectionConfig, String?, _ connect: Bool) -> Void
    let onCancel: () -> Void

    @State private var testState: TestState = .idle

    enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $config.kind) {
                        ForEach(DatabaseKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: config.kind) { old, new in
                        if config.port == old.defaultPort || config.port == 0 { config.port = new.defaultPort }
                        if new == .mysql && config.tls == .disable { config.tls = .require }
                    }
                    TextField("Name", text: $config.name, prompt: Text(config.displayName.isEmpty ? "My database" : config.displayName))
                    Picker("Tag", selection: $config.tag) {
                        ForEach(ConnectionTag.allCases) { Text($0.displayName).tag($0) }
                    }
                }

                if config.kind.isFileBased {
                    Section("Database file") {
                        HStack {
                            TextField("Path", text: $config.filePath, prompt: Text("/path/to/database.sqlite"))
                            Button("Browse…") { browse(create: false) }
                            Button("New…") { browse(create: true) }
                        }
                    }
                } else {
                    Section("Server") {
                        TextField("Host", text: $config.host, prompt: Text("127.0.0.1"))
                        TextField("Port", value: $config.port, format: .number.grouping(.never))
                        if config.kind == .redis {
                            TextField("User", text: $config.user, prompt: Text("optional (ACL user, Redis 6+)"))
                            SecureField("Password", text: $password, prompt: Text("optional"))
                            TextField("Database", text: $config.database, prompt: Text("0"))
                        } else {
                            TextField("User", text: $config.user)
                            SecureField("Password", text: $password)
                            TextField("Database", text: $config.database, prompt: Text(config.kind == .postgres ? "defaults to the user name" : "optional"))
                        }
                        Picker("TLS", selection: $config.tls) {
                            ForEach(TLSMode.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Test") { Task { await test() } }
                    .disabled(testState == .testing || !isValid)
                testStatus
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(config, password, false) }
                    .disabled(!isValid)
                Button("Connect") { onSave(config, password, true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 520)
        .navigationTitle(isNew ? "New Connection" : "Edit Connection")
    }

    private var isValid: Bool {
        switch config.kind {
        case .sqlite: return !config.filePath.isEmpty
        case .redis:
            let database = config.database.trimmingCharacters(in: .whitespaces)
            return (1...65535).contains(config.port) && (database.isEmpty || (Int(database).map { $0 >= 0 } ?? false))
        case .postgres, .mysql: return !config.user.isEmpty && (1...65535).contains(config.port)
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                .help(message)
        }
    }

    private func test() async {
        testState = .testing
        do {
            if config.kind == .redis {
                let redis = try await RedisDriver.connect(config, password: password)
                let pong = try await redis.send("PING")
                await redis.close()
                if case .error(let message) = pong { throw DatabaseError(message) }
                testState = .success(redis.serverDescription)
                return
            }
            let driver = try await DriverFactory.connect(config, password: password)
            let version = try? await driver.execute(config.kind == .sqlite ? "SELECT 'SQLite ' || sqlite_version()" : "SELECT version()")
            await driver.close()
            let text = (version?.rows.first?.first ?? nil).map { String($0.prefix(48)) } ?? "Connected"
            testState = .success(text)
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    private func browse(create: Bool) {
        if create {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "database.sqlite"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            config.filePath = url.path
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            config.filePath = url.path
        }
        if config.name.isEmpty { config.name = (config.filePath as NSString).lastPathComponent }
    }
}
