import AppKit
import SwiftUI
import TabulaCore

/// Entity-relationship diagram of one schema, built from foreign keys.
@MainActor @Observable
final class DiagramModel {
    struct Node: Identifiable {
        let table: TableRef
        let columns: [ColumnInfo]
        var position: CGPoint
        var id: String { table.id }
    }

    let id = UUID()
    let schema: String
    private let driver: any DatabaseDriver
    private(set) var nodes: [Node] = []
    private(set) var foreignKeys: [ForeignKeyInfo] = []
    private(set) var loading = false
    var error: String?
    var selected: String?
    /// Kept between `minZoom` and `maxZoom`. The setter clamps: a `didSet` that assigns `zoom` again calls
    /// itself without end in an @Observable class, which crashed the app on the first zoom.
    var zoom: CGFloat {
        get { scale }
        set { scale = min(Self.maxZoom, max(Self.minZoom, newValue)) }
    }
    private var scale: CGFloat = 1
    static let minZoom: CGFloat = 0.3
    static let maxZoom: CGFloat = 2
    static let zoomStep: CGFloat = 0.15
    /// Room around the outermost tables, and the canvas size of an empty diagram.
    static let canvasMargin: CGFloat = 60
    static let emptyCanvas = CGSize(width: 400, height: 300)
    var showAllColumns = true

    static let nodeWidth: CGFloat = 210
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 18
    static let maxRows = 14

    init(schema: String, driver: any DatabaseDriver) {
        self.schema = schema
        self.driver = driver
    }

    var title: String { "Diagram · \(schema)" }

    func visibleColumns(_ node: Node) -> [ColumnInfo] {
        let keyColumns = Set(foreignKeys.filter { $0.table == node.table }.flatMap(\.columns))
        let columns = showAllColumns ? node.columns : node.columns.filter { $0.isPrimaryKey || keyColumns.contains($0.name) }
        return Array(columns.prefix(Self.maxRows))
    }

    func height(_ node: Node) -> CGFloat {
        let count = visibleColumns(node).count
        let hidden = (showAllColumns ? node.columns.count : count) > Self.maxRows
        return Self.headerHeight + CGFloat(count + (hidden ? 1 : 0)) * Self.rowHeight + 6
    }

    var canvasSize: CGSize {
        let maxX = nodes.map { $0.position.x + Self.nodeWidth }.max() ?? Self.emptyCanvas.width
        let maxY = nodes.map { $0.position.y + height($0) }.max() ?? Self.emptyCanvas.height
        return CGSize(width: maxX + Self.canvasMargin, height: maxY + Self.canvasMargin)
    }

    func load() async {
        // The Reload button and the view's first appearance must not load twice at once.
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let tables = try await driver.tables(in: schema).filter { $0.kind == .table }.prefix(Defaults.Diagram.tableLimit)
            foreignKeys = try await driver.foreignKeys(in: schema)
            var loaded: [Node] = []
            for table in tables {
                loaded.append(Node(table: table, columns: (try? await driver.columns(of: table)) ?? [], position: .zero))
            }
            nodes = loaded
            layout()
            error = tables.isEmpty ? "No tables in \(schema)." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Referenced tables to the left of the tables that reference them; unrelated tables in a grid at the end.
    func layout() {
        let names = Set(nodes.map(\.table.name))
        var references: [String: Set<String>] = [:]
        for key in foreignKeys where names.contains(key.referencedTable.name) && key.referencedTable.name != key.table.name {
            references[key.table.name, default: []].insert(key.referencedTable.name)
        }
        var level: [String: Int] = [:]
        for _ in 0..<nodes.count {
            var changed = false
            for node in nodes {
                let parents = references[node.table.name] ?? []
                let value = parents.isEmpty ? 0 : (parents.compactMap { level[$0] }.max() ?? 0) + 1
                if level[node.table.name] != min(value, 12) { level[node.table.name] = min(value, 12); changed = true }
            }
            if !changed { break }
        }
        let connected = Set(references.keys).union(references.values.flatMap { $0 })
        var columnHeights: [Int: CGFloat] = [:]
        let gapX: CGFloat = 90, gapY: CGFloat = 28
        for index in nodes.indices.sorted(by: { nodes[$0].table.name < nodes[$1].table.name }) where connected.contains(nodes[index].table.name) {
            let column = level[nodes[index].table.name] ?? 0
            let y = columnHeights[column, default: 30]
            nodes[index].position = CGPoint(x: 30 + CGFloat(column) * (Self.nodeWidth + gapX), y: y)
            columnHeights[column] = y + height(nodes[index]) + gapY
        }
        // Tables without relationships: a grid below the connected part.
        let lonely = nodes.indices.filter { !connected.contains(nodes[$0].table.name) }.sorted { nodes[$0].table.name < nodes[$1].table.name }
        let top = (columnHeights.values.max() ?? 30) + (connected.isEmpty ? 0 : 30)
        let perRow = max(3, (columnHeights.keys.max() ?? 0) + 1)
        var rowTop = top, rowHeight: CGFloat = 0
        for (offset, index) in lonely.enumerated() {
            if offset > 0 && offset % perRow == 0 { rowTop += rowHeight + gapY; rowHeight = 0 }
            nodes[index].position = CGPoint(x: 30 + CGFloat(offset % perRow) * (Self.nodeWidth + gapX), y: rowTop)
            rowHeight = max(rowHeight, height(nodes[index]))
        }
    }

    func move(_ id: String, to point: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].position = CGPoint(x: max(0, point.x), y: max(0, point.y))
    }

    /// Y offset (from the node top) of a column's row, or the header when it isn't shown.
    func rowY(_ node: Node, column: String?) -> CGFloat {
        let columns = visibleColumns(node)
        guard let column, let index = columns.firstIndex(where: { $0.name == column }) else { return Self.headerHeight / 2 }
        return Self.headerHeight + CGFloat(index) * Self.rowHeight + Self.rowHeight / 2 + 3
    }
}

struct DiagramView: View {
    @Bindable var model: DiagramModel
    let onOpen: (TableRef) -> Void
    @State private var dragStart: [String: CGPoint] = [:]
    @State private var pinchStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let error = model.error { ErrorBanner(message: error) { model.error = nil } }
            if model.loading && model.nodes.isEmpty {
                ProgressView("Reading schema…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    canvas
                        .frame(width: model.canvasSize.width, height: model.canvasSize.height, alignment: .topLeading)
                        .scaleEffect(model.zoom, anchor: .topLeading)
                        .frame(width: model.canvasSize.width * model.zoom, height: model.canvasSize.height * model.zoom, alignment: .topLeading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                // Magnification is relative to where the pinch started.
                .gesture(MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil { pinchStart = model.zoom }
                        model.zoom = (pinchStart ?? 1) * value.magnification
                    }
                    .onEnded { _ in pinchStart = nil })
            }
        }
        .task { if model.nodes.isEmpty { await model.load() } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("\(model.nodes.count) tables · \(model.foreignKeys.count) relationships").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Toggle("All columns", isOn: $model.showAllColumns).toggleStyle(.checkbox)
                .onChange(of: model.showAllColumns) { _, _ in model.layout() }
            Divider().frame(height: 16)
            BarButton(symbol: "minus.magnifyingglass", help: "Zoom out") { model.zoom -= DiagramModel.zoomStep }
            Text("\(Int(model.zoom * 100))%").font(.system(size: 11).monospacedDigit()).frame(width: 38)
            BarButton(symbol: "plus.magnifyingglass", help: "Zoom in") { model.zoom += DiagramModel.zoomStep }
            BarButton(symbol: "rectangle.3.group", help: "Arrange automatically") { model.layout() }
            BarButton(symbol: "arrow.clockwise", help: "Reload schema") { Task { await model.load() } }
            BarButton(symbol: "square.and.arrow.down", help: "Export PNG") { exportPNG() }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in drawEdges(in: &context) }
            ForEach(model.nodes) { node in
                TableNode(model: model, node: node, selected: model.selected == node.id)
                    .position(x: node.position.x + DiagramModel.nodeWidth / 2, y: node.position.y + model.height(node) / 2)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let start = dragStart[node.id] ?? node.position
                                dragStart[node.id] = start
                                model.move(node.id, to: CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height))
                            }
                            .onEnded { _ in dragStart[node.id] = nil }
                    )
                    .onTapGesture(count: 2) { onOpen(node.table) }
                    .onTapGesture { model.selected = model.selected == node.id ? nil : node.id }
            }
        }
    }

    private func drawEdges(in context: inout GraphicsContext) {
        let byName = Dictionary(model.nodes.map { ($0.table.name, $0) }, uniquingKeysWith: { a, _ in a })
        for key in model.foreignKeys {
            guard let from = byName[key.table.name], let to = byName[key.referencedTable.name] else { continue }
            let highlighted = model.selected == nil || model.selected == from.id || model.selected == to.id
            let targetColumn = key.referencedColumns.first ?? to.columns.first(where: \.isPrimaryKey)?.name
            let fromY = from.position.y + model.rowY(from, column: key.columns.first)
            let toY = to.position.y + model.rowY(to, column: targetColumn)
            let width = DiagramModel.nodeWidth
            var path = Path()
            let start: CGPoint, end: CGPoint, bend: CGFloat
            if from.id == to.id {
                // Self reference: a loop on the right.
                start = CGPoint(x: from.position.x + width, y: fromY)
                end = CGPoint(x: from.position.x + width, y: toY)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x + 50, y: start.y), control2: CGPoint(x: end.x + 50, y: end.y))
            } else {
                let leftToRight = to.position.x + width < from.position.x
                start = CGPoint(x: leftToRight ? from.position.x : from.position.x + width, y: fromY)
                end = CGPoint(x: leftToRight ? to.position.x + width : to.position.x, y: toY)
                bend = max(40, abs(end.x - start.x) / 2)
                path.move(to: start)
                path.addCurve(to: end, control1: CGPoint(x: start.x + (leftToRight ? -bend : bend), y: start.y),
                              control2: CGPoint(x: end.x + (leftToRight ? bend : -bend), y: end.y))
            }
            let color = highlighted ? Color.accentColor : Color.secondary.opacity(0.25)
            context.stroke(path, with: .color(color), lineWidth: highlighted && model.selected != nil ? 2 : 1.3)
            // Many side: small fork; one side: a dot.
            context.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(color))
            var fork = Path()
            let direction: CGFloat = start.x <= from.position.x + 1 ? -1 : 1
            fork.move(to: CGPoint(x: start.x + 10 * direction, y: start.y))
            fork.addLine(to: CGPoint(x: start.x, y: start.y - 5))
            fork.move(to: CGPoint(x: start.x + 10 * direction, y: start.y))
            fork.addLine(to: CGPoint(x: start.x, y: start.y + 5))
            context.stroke(fork, with: .color(color), lineWidth: 1.3)
        }
    }

    private func exportPNG() {
        let renderer = ImageRenderer(content: canvas.frame(width: model.canvasSize.width, height: model.canvasSize.height)
            .background(Color(nsColor: .textBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.schema)-diagram.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }
}

private struct TableNode: View {
    let model: DiagramModel
    let node: DiagramModel.Node
    let selected: Bool

    var body: some View {
        let columns = model.visibleColumns(node)
        let foreignColumns = Set(model.foreignKeys.filter { $0.table == node.table }.flatMap(\.columns))
        let hiddenCount = (model.showAllColumns ? node.columns.count : columns.count) - columns.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "tablecells").font(.system(size: 10))
                Text(node.table.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: DiagramModel.headerHeight)
            .background(selected ? Color.accentColor : Color.accentColor.opacity(0.75))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(columns) { column in
                    HStack(spacing: 4) {
                        Group {
                            if column.isPrimaryKey {
                                Image(systemName: "key.fill").foregroundStyle(.yellow)
                            } else if foreignColumns.contains(column.name) {
                                Image(systemName: "arrow.turn.down.right").foregroundStyle(Color.accentColor)
                            } else {
                                Color.clear
                            }
                        }
                        .font(.system(size: 8))
                        .frame(width: 10)
                        Text(column.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(column.dataType).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .frame(height: DiagramModel.rowHeight)
                }
                if hiddenCount > 0 {
                    Text("+ \(hiddenCount) more").font(.system(size: 10)).foregroundStyle(.tertiary).frame(height: DiagramModel.rowHeight)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .frame(width: DiagramModel.nodeWidth, height: model.height(node), alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .help("Drag to move · double-click to open \(node.table.name)")
    }
}
