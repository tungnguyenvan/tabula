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

    /// Fills the form from a connection string (a URL, JDBC URL or key=value pairs) pasted into the Host field.
    private func applyURL(_ text: String, replacing oldHost: String) {
        guard let (parsed, parsedPassword) = ConnectionConfig.parse(connectionString: text) else { return }
        var filled = parsed
        filled.id = config.id
        if filled.name.isEmpty { filled.name = config.name }
        if filled.tag == ConnectionConfig().tag { filled.tag = config.tag }
        filled.connectTimeout = config.connectTimeout
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
        case .postgres, .mysql: return !config.user.isEmpty && (1...65535).contains(config.port)
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
            let version = await driver.serverVersion()
            await driver.close()
            let text = version.map { String($0.prefix(Layout.versionLength)) } ?? "Connected"
            testState = .success(text)
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
