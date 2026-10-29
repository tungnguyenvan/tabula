import SwiftUI
import TabulaFoundation

/// ⌘P: type to jump to a table, an open tab, or an action. ↑↓ choose, ↩ open, ⌥↩ structure, ⎋ close.
struct CommandPaletteView: View {
    let model: WorkspaceModel
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        enum Kind {
            case table(TableRef)
            case tab(UUID)
            case action(() -> Void)
        }
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let kind: Kind
    }

    private var allItems: [Item] {
        var items: [Item] = model.tables.map { table in
            Item(
                id: "table:\(table.id)",
                title: table.name,
                subtitle: table.kind == .view ? "View · \(table.schema)" : "Table · \(table.schema)",
                symbol: table.kind == .view ? "eye" : "tablecells",
                kind: .table(table)
            )
        }
        items += model.tabs.map { tab in
            Item(
                id: "tab:\(tab.id)",
                title: tab.title,
                subtitle: "Open tab",
                symbol: "square.on.square",
                kind: .tab(tab.id)
            )
        }
        items.append(
            Item(
                id: "action:query",
                title: "New Query",
                subtitle: "⌘T",
                symbol: "plus.square",
                kind: .action { model.newQueryTab() }
            )
        )
        if model.config.kind.supportsDiagram {
            items.append(
                Item(
                    id: "action:diagram",
                    title: "Relationship Diagram",
                    subtitle: "⌥⌘3",
                    symbol: "point.3.connected.trianglepath.dotted",
                    kind: .action { model.openDiagram() }
                )
            )
        }
        items += [
            Item(
                id: "action:metrics",
                title: "Server Metrics",
                subtitle: "⌥⌘4",
                symbol: "gauge.with.dots.needle.33percent",
                kind: .action { model.openMetrics() }
            ),
            Item(
                id: "action:refresh",
                title: "Refresh",
                subtitle: "⌘R",
                symbol: "arrow.clockwise",
                kind: .action { Task { await model.refresh() } }
            ),
            Item(
                id: "action:inspector",
                title: "Toggle Row Details",
                subtitle: "⌥⌘0",
                symbol: "sidebar.right",
                kind: .action { model.showInspector.toggle() }
            ),
        ]
        items += model.schemas.filter { $0 != model.selectedSchema }
            .map { schema in
                Item(
                    id: "schema:\(schema)",
                    title: "Switch to \(schema)",
                    subtitle: model.config.kind == .mysql ? "Database" : "Schema",
                    symbol: "arrow.left.arrow.right",
                    kind: .action { Task { await model.selectSchema(schema) } }
                )
            }
        return items
    }

    private var results: [Item] {
        guard !query.isEmpty else {
            return Array(allItems.prefix(50))
        }
        return
            allItems
            .compactMap { item in Self.score(item.title, query).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(50)
            .map(\.0)
    }

    /// The query's letters in order; consecutive and word-start hits score higher, and shorter names win a tie.
    /// Each letter is first matched where it first appears, which can miss a better place ("ord" in
    /// work_order_lines would use the "or" of "work"), so the query as one run at its best place counts too.
    static func score(_ text: String, _ query: String) -> Int? {
        let haystack = Array(text.lowercased())
        let needle = Array(query.lowercased())
        guard let inOrder = scoreInOrder(haystack, needle) else { return nil }
        return max(inOrder, scoreAsRun(haystack, needle) ?? 0) * 100 - haystack.count
    }

    private static func isWordStart(_ haystack: [Character], _ index: Int) -> Bool {
        index == 0 || "_ .-".contains(haystack[index - 1])
    }

    private static func scoreInOrder(_ haystack: [Character], _ needle: [Character]) -> Int? {
        var score = 0
        var position = 0
        var previous = -2
        for character in needle {
            guard let found = haystack[position...].firstIndex(of: character) else { return nil }
            score += found == previous + 1 ? 5 : 1
            if isWordStart(haystack, found) { score += 3 }
            previous = found
            position = found + 1
        }
        return score
    }

    /// The best place the whole query appears as it is, scored like the in-order match of the same letters.
    private static func scoreAsRun(_ haystack: [Character], _ needle: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var best: Int?
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            var score = 1 + (needle.count - 1) * 5
            for offset in 0..<needle.count where isWordStart(haystack, start + offset) {
                score += 3
            }
            best = max(best ?? score, score)
        }
        return best
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to table, tab or action…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit {
                        activate(results.indices.contains(highlighted) ? results[highlighted] : nil, structure: false)
                    }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == highlighted)
                                .id(item.id)
                                .onTapGesture { activate(item, structure: false) }
                        }
                        if results.isEmpty {
                            Text("No matches").font(.callout).foregroundStyle(.tertiary).padding(16)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
                .onChange(of: highlighted) { _, index in
                    if results.indices.contains(index) {
                        proxy.scrollTo(results[index].id)
                    }
                }
            }
            Divider()
            Text("↑↓ choose   ↩ open   ⌥↩ open structure   ⎋ close")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(6)
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(highlighted - 1, 0)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.option) else {
                return .ignored
            }
            activate(results.indices.contains(highlighted) ? results[highlighted] : nil, structure: true)
            return .handled
        }
        .onExitCommand { model.showPalette = false }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).frame(width: 18).foregroundStyle(selected ? .white : .secondary)
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundStyle(selected ? .white : .primary)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func activate(_ item: Item?, structure: Bool) {
        model.showPalette = false
        guard let item else { return }
        switch item.kind {
        case .table(let table): model.open(table, mode: structure ? .structure : .data)
        case .tab(let id): model.selectedTabID = id
        case .action(let action): action()
        }
    }
}
