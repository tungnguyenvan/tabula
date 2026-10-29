import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

/// Model files Tabula runs itself: the catalog's downloads and files the user added.
@MainActor @Observable
final class BuiltInModels {
    static let shared = BuiltInModels()
    let store = LocalModelStore()
    private(set) var installed: [(id: String, size: Int64)] = []
    /// Model id → download progress (0…1).
    private(set) var downloads: [String: Double] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    var error: String?

    private init() { refresh() }

    func refresh() { installed = store.installed() }

    static func name(of id: String) -> String {
        LocalModel.catalog.first { $0.id == id }?.name ?? id
    }

    func download(_ model: LocalModel, then: @escaping @MainActor () -> Void) {
        guard tasks[model.id] == nil else { return }
        downloads[model.id] = 0
        let store = store
        tasks[model.id] = Task {
            do {
                try await store.download(model) { fraction in
                    Task { @MainActor in self.downloads[model.id] = fraction }
                }
                error = nil
                then()
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = "\(model.name): \(error.localizedDescription)"
            }
            downloads[model.id] = nil
            tasks[model.id] = nil
            refresh()
        }
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    func add(_ file: URL) -> String? {
        do {
            let id = try store.add(file)
            error = nil
            refresh()
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func delete(_ id: String) {
        LocalModelRunner.shared.unload()
        do {
            try store.delete(id)
            error = nil
        } catch { self.error = error.localizedDescription }
        refresh()
    }
}

struct BuiltInModelsSection: View {
    @Bindable private var ai = AIService.shared
    @State private var models = BuiltInModels.shared
    @State private var addingLink = false
    @State private var link = ""

    private var extraModels: [(id: String, size: Int64)] {
        models.installed.filter { installed in !LocalModel.catalog.contains { $0.id == installed.id } }
    }

    var body: some View {
        Section {
            ForEach(LocalModel.catalog) { model in
                row(id: model.id, name: model.name, detail: "\(size(model.size)) · \(model.summary)") {
                    downloadButton(model)
                }
            }
            ForEach(extraModels, id: \.id) { model in
                row(id: model.id, name: model.id, detail: size(model.size)) { EmptyView() }
            }
            HStack {
                Button("Add Model File…", action: chooseFile)
                Button("Add from Link…") { addingLink = true }
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(
                        at: models.store.directory,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([models.store.directory])
                }
            }
            if let error = models.error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Models on this Mac")
        } footer: {
            Text(
                "Models run inside Tabula and never leave this Mac. Any GGUF model works: add a file, or a link to one (for example from Hugging Face). Models are stored in Tabula's folder, not in the app."
            )
        }
        .onAppear { models.refresh() }
        .sheet(isPresented: $addingLink) { linkSheet }
    }

    private func row(id: String, name: String, detail: String, @ViewBuilder notInstalled: () -> some View) -> some View
    {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = models.downloads[id] {
                ProgressView(value: progress).frame(width: Layout.Settings.progressWidth)
                Button {
                    models.cancel(id)
                } label: {
                    Label("Stop Downloading", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless).help("Stop downloading")
            } else if models.installed.contains(where: { $0.id == id }) {
                Menu {
                    Button("Use for Ask AI") { use(id, for: .generate) }
                    Button("Use for Suggestions While Typing") { use(id, for: .inline) }
                    Divider()
                    Button("Delete", role: .destructive) { models.delete(id) }
                } label: {
                    Text(usage(id))
                }
                .fixedSize()
            } else {
                notInstalled()
            }
        }
    }

    private func downloadButton(_ model: LocalModel) -> some View {
        Button("Download") {
            models.download(model) { use(model.id, for: model.forTyping ? .inline : .generate) }
        }
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding * 2) {
            Text("Add a model from a link").font(.headline)
            Text("A direct link to a .gguf file, such as a Hugging Face “resolve/main/…gguf” URL.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://huggingface.co/…/resolve/main/model.gguf", text: $link)
                .textFieldStyle(.roundedBorder)
                .frame(width: Layout.Settings.width - Layout.barPadding * 8)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { addingLink = false }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
                    do {
                        let model = try models.store.model(from: url)
                        models.download(model) { use(model.id, for: .generate) }
                        addingLink = false
                        link = ""
                    } catch {
                        models.error = error.localizedDescription
                        addingLink = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: link.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") != true)
            }
        }
        .padding(Layout.barPadding * 2)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GGUF model file"
        guard panel.runModal() == .OK, let url = panel.url, let id = models.add(url) else { return }
        use(id, for: .generate)
    }

    private func use(_ id: String, for purpose: AIRequest.Purpose) {
        let key = AIProviderKind.builtIn.rawValue
        if purpose == .inline {
            ai.settings.inlineSuggestions = true
            if ai.settings.provider != .builtIn {
                ai.settings.inlineProvider = .builtIn
            }
            ai.settings.inlineModels[key] = id
        } else {
            ai.settings.provider = .builtIn
            ai.settings.models[key] = id
        }
    }

    private func usage(_ id: String) -> String {
        let assistant = ai.settings.provider == .builtIn && ai.settings.model(.builtIn, for: .generate) == id
        let typing = ai.settings.provider(for: .inline) == .builtIn && ai.settings.model(.builtIn, for: .inline) == id
        switch (assistant, typing) {
        case (true, true): return "Used for both"
        case (true, false): return "Used for Ask AI"
        case (false, true): return "Used for suggestions"
        case (false, false): return "Downloaded"
        }
    }

    private func size(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Size unknown"
    }
}
