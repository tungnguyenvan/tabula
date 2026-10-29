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
    /// Set while a pasted URL fills the form, so changing the type doesn't reset the port and TLS it set.
    @State private var applyingURL = false

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
                        if new != .postgres && new != .mysql { config.ssh = nil }
                        if applyingURL { applyingURL = false; return }
                        if config.port == old.defaultPort || config.port == 0 { config.port = new.defaultPort }
                        if new == .mysql && config.tls == .disable { config.tls = .require }
                        if new != .mongodb { config.srv = nil; config.authSource = nil }
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
                        TextField("Host", text: $config.host, prompt: Text(hostPrompt))
                            .help("Paste a connection string, such as postgresql://user:password@host:5432/db or host=… dbname=… user=…, to fill in every field.")
                            .onChange(of: config.host) { old, host in
                                // Typing "postgres://…" key by key, or deleting from the end, must stay typing.
                                let typed = host.count == old.count + 1 && host.hasPrefix(old)
                                if !typed && !old.hasPrefix(host) { applyURL(host, replacing: old) }
                            }
                        if config.kind == .mongodb {
                            Toggle("DNS seed list (mongodb+srv)", isOn: srv)
                                .help("For hosts such as cluster0.example.mongodb.net (MongoDB Atlas). The port comes from DNS.")
                        }
                        if !(config.kind == .mongodb && config.srv == true) {
                            TextField("Port", value: $config.port, format: .number.grouping(.never))
                        }
                        if config.kind == .redis {
                            TextField("User", text: $config.user, prompt: Text("optional (ACL user, Redis 6+)"))
                            passwordField(prompt: "optional")
                            TextField("Database", text: $config.database, prompt: Text("0"))
                        } else if config.kind == .mongodb {
                            TextField("User", text: $config.user, prompt: Text("optional"))
                            passwordField(prompt: "optional")
                            TextField("Database", text: $config.database, prompt: Text(Defaults.Mongo.defaultDatabase))
                            TextField("Auth database", text: authSource, prompt: Text(Defaults.Mongo.authDatabase))
                        } else {
                            TextField("User", text: $config.user)
                            passwordField(prompt: nil)
                            TextField("Database", text: $config.database, prompt: Text(config.kind == .postgres ? "defaults to the user name" : "optional"))
                        }
                        Picker("TLS", selection: $config.tls) {
                            ForEach(TLSMode.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    if config.kind == .postgres || config.kind == .mysql {
                        sshSection
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
        .frame(width: Layout.ConnectionForm.width)
        .navigationTitle(isNew ? "New Connection" : "Edit Connection")
        #if DEBUG
        .onAppear {
            if let host = DebugHooks.formHost { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { config.host = host } }
            // TABULA_DEBUG_FORM_TEST: press Test once the form is up.
            if ProcessInfo.processInfo.environment["TABULA_DEBUG_FORM_TEST"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { await test() } }
            }
        }
        #endif
    }

    /// The password, with a way to decode it when it holds URL escapes (`%3F` for `?`): some dashboards show
    /// passwords that way, and the server would get the escapes as they are.
    @ViewBuilder
    private func passwordField(prompt: String?) -> some View {
        SecureField("Password", text: $password, prompt: prompt.map { Text($0) })
        if let decoded = PasswordEscapes.decoded(password) {
            LabeledContent {
                Button("Decode") { password = decoded }
                    .help("Replaces each %xx escape with the character it stands for, such as %3F with ?.")
            } label: {
                Label("This password contains URL escapes such as %3F. If you copied it from a URL or a dashboard, decode it.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// An SSH server the connection goes through. The Host above is then the database as the SSH server reaches it.
    @ViewBuilder
    private var sshSection: some View {
        Section {
            Toggle("Connect over SSH", isOn: sshEnabled)
                .help("Reaches a database that only an SSH server (a bastion) can reach, through a tunnel from this Mac.")
            if config.ssh != nil {
                TextField("SSH host", text: sshField(\.host), prompt: Text("bastion.example.com"))
                TextField("SSH port", value: sshField(\.port), format: .number.grouping(.never))
                TextField("SSH user", text: sshField(\.user))
                LabeledContent("Key") {
                    HStack {
                        Text(config.ssh?.identityFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "ssh-agent and default keys")
                            .foregroundStyle(config.ssh?.identityFile == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseKey)
                            .help("Use one private key file instead of ssh-agent and the default keys.")
                        if config.ssh?.identityFile != nil {
                            Button("Clear") { config.ssh?.identityFile = nil }
                                .help("Use ssh-agent and the default keys.")
                        }
                    }
                }
                if let problem = sshProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("SSH tunnel")
        } footer: {
            if config.ssh != nil {
                Text("Keys only: from ssh-agent, ~/.ssh or the chosen file. A key with a passphrase must be added to ssh-agent first (ssh-add). The server's host key must already be in ~/.ssh/known_hosts; connect once with ssh in Terminal to add it. Host above is the database as the SSH server reaches it, such as localhost.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sshEnabled: Binding<Bool> {
        Binding { config.ssh != nil } set: { on in
            config.ssh = on ? (config.ssh ?? SSHConfig(user: NSUserName())) : nil
            testState = .idle
        }
    }

    private func sshField<Value>(_ keyPath: WritableKeyPath<SSHConfig, Value>) -> Binding<Value> {
        Binding { (config.ssh ?? SSHConfig())[keyPath: keyPath] } set: { config.ssh?[keyPath: keyPath] = $0 }
    }

    /// Shown once the SSH host and user are filled in, so an empty new section isn't all warnings.
    private var sshProblem: String? {
        guard let ssh = config.ssh, !ssh.host.isEmpty, !ssh.user.isEmpty else { return nil }
        return ssh.problem
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose the private key, such as id_ed25519 (not the .pub file)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.ssh?.identityFile = url.path
        testState = .idle
    }

    /// Fills the form from a connection string (a URL, JDBC URL or key=value pairs) pasted into the Host field.
    private func applyURL(_ text: String, replacing oldHost: String) {
        guard let (parsed, parsedPassword) = ConnectionConfig.parse(connectionString: text) else { return }
        var filled = parsed
        filled.id = config.id
        if filled.name.isEmpty { filled.name = config.name }
        if filled.tag == ConnectionConfig().tag { filled.tag = config.tag }
        filled.connectTimeout = config.connectTimeout
        // A URL names the database, not how to reach it: the SSH server stays, for the kinds that can use it.
        filled.ssh = filled.kind == .postgres || filled.kind == .mysql ? config.ssh : nil
        let kindBeforeURL = config.kind
        if filled.kind != config.kind { applyingURL = true }
        config = filled
        // A URL without a password keeps the saved one only for the same server; it isn't sent to another.
        if let parsedPassword {
            password = parsedPassword
        } else if filled.host != oldHost || filled.kind != kindBeforeURL {
            password = ""
        }
        testState = .idle
    }

    private var isValid: Bool {
        switch config.kind {
        case .sqlite: return !config.filePath.isEmpty
        case .redis:
            let database = config.database.trimmingCharacters(in: .whitespaces)
            return (1...65535).contains(config.port) && (database.isEmpty || (Int(database).map { $0 >= 0 } ?? false))
        case .postgres, .mysql:
            return !config.user.isEmpty && (1...65535).contains(config.port) && config.ssh?.problem == nil
        case .mongodb: return !config.host.isEmpty && (config.srv == true || (1...65535).contains(config.port))
        }
    }

    private var hostPrompt: String {
        guard config.kind == .mongodb else { return Defaults.host }
        return config.srv == true ? "cluster0.example.mongodb.net" : "\(Defaults.host)  (or a:27017,b:27017)"
    }

    private var srv: Binding<Bool> {
        Binding { config.srv == true } set: { on in
            config.srv = on ? true : nil
            // Seed lists (Atlas) always use TLS.
            if on && config.tls == .disable { config.tls = .verifyFull }
        }
    }

    private var authSource: Binding<String> {
        Binding { config.authSource ?? "" } set: { config.authSource = $0.isEmpty ? nil : $0 }
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
                let pong: RedisReply
                do {
                    pong = try await redis.send("PING")
                } catch {
                    await redis.close()
                    throw error
                }
                await redis.close()
                if case .error(let message) = pong { throw DatabaseError(message) }
                testState = .success(redis.serverDescription)
                return
            }
            let driver = try await DriverFactory.connect(config, password: password)
            let version: String
            do {
                version = try await driver.serverVersion()
            } catch {
                await driver.close()
                throw error
            }
            await driver.close()
            testState = .success(String(version.prefix(Layout.versionLength)))
        } catch {
            testState = .failure(PasswordEscapes.message(for: error, password: password))
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
