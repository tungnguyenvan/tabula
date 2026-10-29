import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

/// Local models served by Ollama, for the AI settings.
@MainActor @Observable
final class OllamaModels {
    private(set) var version: String?
    private(set) var installed: [OllamaLibrary.InstalledModel] = []
    /// Model name → download progress (nil fraction while Ollama prepares).
    private(set) var downloads: [String: OllamaLibrary.PullProgress] = [:]
    private(set) var checked = false
    var error: String?
    private var library: OllamaLibrary {
        OllamaLibrary(baseURL: AIEndpoint(kind: .ollama, baseURL: AIService.shared.settings.baseURL(.ollama)).baseURL)
    }

    func refresh() async {
        version = await library.version()
        defer {
            checked = true
        }
        // Not running: the settings say so through `version`; there is nothing to list.
        guard version != nil else {
            installed = []
            return
        }
        do {
            installed = try await library.installed()
        } catch {
            // Running but its list can't be read: say so rather than showing every model as not installed.
            self.error = "Couldn't list the installed models: \(error.localizedDescription)"
        }
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { $0.name == name || $0.name == name + ":latest" }
    }

    /// Downloads a model; `then` runs once it is installed (e.g. to start using it).
    func download(_ name: String, then: @escaping @MainActor () -> Void = {}) {
        guard downloads[name] == nil else { return }
        downloads[name] = OllamaLibrary.PullProgress(status: "Starting…", fraction: nil)
        let library = library
        Task {
            do {
                try await library.pull(name) { progress in
                    Task { @MainActor in self.downloads[name] = progress }
                }
                error = nil
                then()
            } catch {
                self.error = error.localizedDescription
            }
            downloads[name] = nil
            await refresh()
        }
    }

    func delete(_ name: String) {
        let library = library
        Task {
            do {
                try await library.delete(name)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }
}

struct LocalModelsSection: View {
    let ollama: OllamaModels
    @Bindable private var ai = AIService.shared

    var body: some View {
        Section {
            if !ollama.checked {
                ProgressView().controlSize(.small)
            } else if ollama.version == nil {
                Label(
                    "Ollama runs the models on this Mac. Install it, open it, then come back here to download one.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                HStack {
                    Link("Download Ollama", destination: URL(string: "https://ollama.com/download")!)
                    Spacer()
                    Button("Check Again") { Task { await ollama.refresh() } }
                }
            } else {
                ForEach(Defaults.AI.recommendedLocalModels) { model in
                    row(name: model.name, summary: model.summary, forTyping: model.forTyping)
                }
                ForEach(
                    ollama.installed.filter { installed in
                        !Defaults.AI.recommendedLocalModels.contains { $0.name == installed.name }
                    }
                ) { model in
                    row(
                        name: model.name,
                        summary: ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file),
                        forTyping: false
                    )
                }
            }
            if let error = ollama.error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Local models")
        } footer: {
            if let version = ollama.version {
                Text("Ollama \(version). Models are downloaded to and run on this Mac.")
            }
        }
    }

    private func row(name: String, summary: String, forTyping: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control(name, forTyping: forTyping)
        }
    }

    @ViewBuilder
    private func control(_ name: String, forTyping: Bool) -> some View {
        if let progress = ollama.downloads[name] {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(width: Layout.Settings.progressWidth)
            } else {
                Text(progress.status).font(.caption).foregroundStyle(.secondary)
            }
        } else if ollama.isInstalled(name) {
            Menu {
                Button("Use for Ask AI") { useForAskAI(name) }
                Button("Use for Suggestions") { useForTyping(name) }
                Divider()
                Button("Delete", role: .destructive) { ollama.delete(name) }
            } label: {
                Text(usage(name))
            }
            .fixedSize()
        } else {
            Button("Download") {
                // Once downloaded, start using it for what it's suited to.
                ollama.download(name) { forTyping ? useForTyping(name) : useForAskAI(name) }
            }
        }
    }

    private func usage(_ name: String) -> String {
        let assistant = ai.settings.provider == .ollama && ai.settings.model(.ollama, for: .generate) == name
        let typing = ai.settings.provider(for: .inline) == .ollama && ai.settings.model(.ollama, for: .inline) == name
        switch (assistant, typing) {
        case (true, true): return "Used for both"
        case (true, false): return "Used for Ask AI"
        case (false, true): return "Used for suggestions"
        case (false, false): return "Installed"
        }
    }

    private func useForAskAI(_ name: String) {
        ai.settings.provider = .ollama
        ai.settings.models[AIProviderKind.ollama.rawValue] = name
    }

    private func useForTyping(_ name: String) {
        ai.settings.inlineSuggestions = true
        if ai.settings.provider != .ollama {
            ai.settings.inlineProvider = .ollama
        }
        ai.settings.inlineModels[AIProviderKind.ollama.rawValue] = name
    }
}
