import AppKit
import SwiftUI
import TabulaRedis

struct RedisConsoleView: View {
    @Bindable var model: RedisConsoleModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Type Redis commands as in redis-cli. ↑↓ history · “clear” clears · SUBSCRIBE/MONITOR are not supported."
                        )
                        .foregroundStyle(.tertiary)
                        ForEach(model.entries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.prompt) ").foregroundStyle(.secondary) + Text(entry.command).bold()
                                Text(entry.output).foregroundStyle(entry.isError ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .id(entry.id)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: model.entries.count) { _, _ in
                    if let last = model.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 6) {
                Text(model.prompt).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                TextField("command", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit {
                        Task {
                            await model.run()
                            focused = true
                        }
                    }
                    .onKeyPress(.upArrow) {
                        model.historyUp()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.historyDown()
                        return .handled
                    }
                if model.running {
                    ProgressView().controlSize(.mini)
                }
                if model.canStop {
                    BarButton(
                        symbol: "stop.fill",
                        help:
                            "Stop the running script or blocking command (⌘.). Redis stops a script once it has run for 5 seconds."
                    ) {
                        Task { await model.stop() }
                    }
                    .keyboardShortcut(".", modifiers: .command)
                    .accessibilityLabel("Stop")
                }
                BarButton(symbol: "trash", help: "Clear output") { model.clear() }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .barBackground()
        }
        .onAppear { focused = true }
    }
}
