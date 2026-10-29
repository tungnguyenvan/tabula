import SwiftUI
import TabulaFoundation

/// Reads a connection string the user pastes in and hands the connection it describes to the New Connection form.
/// Tabula never reads the clipboard by itself; the user pastes, here or into the connection list.
struct ConnectionStringSheet: View {
    @State var text = ""
    let onContinue: (ConnectionConfig, String?) -> Void
    let onCancel: () -> Void

    private var parsed: (config: ConnectionConfig, password: String?)? {
        ConnectionConfig.parse(connectionString: text)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(
                        "Connection string",
                        text: $text,
                        prompt: Text("postgresql://user:password@host:5432/database"),
                        axis: .vertical
                    )
                    .lineLimit(Layout.ConnectionForm.stringLines)
                    .font(Layout.Font.mono)
                    .labelsHidden()
                    summary
                } header: {
                    Text("Connection String")
                } footer: {
                    Text(
                        "A URL (postgresql://, mysql://, mongodb+srv://, redis://, file://), a JDBC URL, or key=value pairs such as host=… dbname=… user=… or Server=…;Database=…;Uid=…."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { if let parsed { onContinue(parsed.config, parsed.password) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
            .padding(12)
        }
        .frame(width: Layout.ConnectionForm.width)
        #if DEBUG
        .onAppear {
            guard DebugHooks.continuesConnectionString, let parsed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { onContinue(parsed.config, parsed.password) }
        }
        #endif
    }

    /// What was read, so a wrong guess (such as the type of a semicolon-separated string) is seen before continuing.
    @ViewBuilder
    private var summary: some View {
        if let (config, password) = parsed {
            Label {
                Text("\(config.kind.displayName) · \(config.subtitle)\(password == nil ? "" : " · with password")")
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("Tabula can’t read this as a connection string.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}
