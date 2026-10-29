import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

/// Which model answers in the chat (and Ask AI), switchable right under the message field.
struct ModelPicker: View {
    @Bindable private var ai = AIService.shared
    private var models = BuiltInModels.shared

    private var current: String {
        let settings = ai.settings
        let kind = settings.provider
        let model = settings.model(kind, for: .generate)
        switch kind {
        case .builtIn: return model.isEmpty ? "Model on this Mac" : BuiltInModels.name(of: model)
        case .anthropic: return kind.suggestedModels.first { $0.id == model }?.name ?? model
        case .appleIntelligence: return "Apple Intelligence"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .ollama, .openAICompatible: return model.isEmpty ? kind.displayName : model
        }
    }

    var body: some View {
        Menu {
            Section("On this Mac") {
                ForEach(models.installed, id: \.id) { model in
                    choice(BuiltInModels.name(of: model.id), kind: .builtIn, model: model.id)
                }
                if models.installed.isEmpty {
                    SettingsLink { Text("Download a Model…") }
                }
                choice("Apple Intelligence", kind: .appleIntelligence, model: "")
                    .disabled(AppleIntelligenceProvider.unavailableReason != nil)
                if let ollama = ai.settings.models[AIProviderKind.ollama.rawValue], !ollama.isEmpty {
                    choice("\(ollama) (Ollama)", kind: .ollama, model: ollama)
                }
            }
            Section("Claude API") {
                ForEach(AIProviderKind.anthropic.suggestedModels, id: \.id) { model in
                    choice(model.name, kind: .anthropic, model: model.id)
                }
            }
            if let openAI = ai.settings.models[AIProviderKind.openAICompatible.rawValue], !openAI.isEmpty {
                Section("OpenAI-compatible") { choice(openAI, kind: .openAICompatible, model: openAI) }
            }
            Section("Installed tools") {
                choice(
                    "Claude Code",
                    kind: .claudeCode,
                    model: ai.settings.models[AIProviderKind.claudeCode.rawValue] ?? ""
                )
                choice("Codex", kind: .codex, model: ai.settings.models[AIProviderKind.codex.rawValue] ?? "")
            }
            Divider()
            SettingsLink { Text("Manage Models…") }
        } label: {
            Label(current, systemImage: "cpu").font(Layout.Font.small)
        }
        .menuStyle(.borderlessButton)
        .help("Model for the chat and Ask AI")
        .onAppear { models.refresh() }
    }

    private func choice(_ title: String, kind: AIProviderKind, model: String) -> some View {
        let selected =
            ai.settings.provider == kind && (model.isEmpty || ai.settings.model(kind, for: .generate) == model)
        return Button {
            ai.settings.provider = kind
            if !model.isEmpty {
                ai.settings.models[kind.rawValue] = model
            }
        } label: {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Effort for the chat's model, when it takes one (recent Claude models, Claude Code, Codex, OpenAI reasoning).
struct ChatEffortPicker: View {
    @Bindable private var ai = AIService.shared

    var body: some View {
        let kind = ai.settings.provider
        if !kind.effortLevels.isEmpty {
            Menu {
                Picker(
                    "Effort",
                    selection: Binding(
                        get: { ai.settings.efforts[kind.rawValue] ?? "" },
                        set: { ai.settings.efforts[kind.rawValue] = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text("Default").tag("")
                    ForEach(kind.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(
                    "Effort: \((ai.settings.efforts[kind.rawValue] ?? "default").capitalized)",
                    systemImage: "gauge.with.dots.needle.50percent"
                )
                .font(Layout.Font.small)
            }
            .menuStyle(.borderlessButton)
            .help("How much the model thinks before answering. Higher is slower and costs more.")
        }
    }
}
