import AppKit
import SwiftUI
import TabulaFoundation

/// Tabs share the bar between 120 and 220 points each, left-aligned; when they don't fit, the bar scrolls
/// and keeps the selected tab in view.
struct TabStrip: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                let width = min(220, max(120, geometry.size.width / CGFloat(max(model.tabs.count, 1))))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(model.tabs) { tab in
                                TabButton(
                                    tab: tab,
                                    selected: tab.id == model.selectedTabID,
                                    isPreview: model.isPreview(tab.id),
                                    select: { model.selectedTabID = tab.id },
                                    pin: { model.pin(tab.id) },
                                    close: { model.requestClose(tab.id) },
                                    closeOthers: {
                                        for other in model.tabs where other.id != tab.id {
                                            model.requestClose(other.id)
                                        }
                                    },
                                    move: { offset in
                                        model.selectedTabID = tab.id
                                        model.moveSelectedTab(by: offset)
                                    },
                                    canMove: { offset in
                                        guard let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else {
                                            return false
                                        }
                                        return model.tabs.indices.contains(index + offset)
                                    }
                                )
                                .frame(width: width)
                                // Drag a tab onto another to put it there, as in Safari and Finder.
                                .draggable(tab.id.uuidString) {
                                    Label(tab.title, systemImage: "doc").padding(6)
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let id = items.first.flatMap(UUID.init(uuidString:)),
                                        model.tabs.contains(where: { $0.id == id })
                                    else { return false }
                                    withAnimation(.easeOut(duration: 0.15)) { model.moveTab(id, to: tab.id) }
                                    return true
                                }
                                .id(tab.id)
                                Divider().frame(height: 14)
                            }
                        }
                        .frame(height: geometry.size.height)
                    }
                    .onChange(of: model.selectedTabID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                    .onAppear {
                        if let id = model.selectedTabID { DispatchQueue.main.async { proxy.scrollTo(id) } }
                    }
                }
            }
            Button {
                model.newQueryTab()
            } label: {
                Label("New Query Tab", systemImage: "plus").labelStyle(.iconOnly)
                    .font(.system(size: 11, weight: .medium)).frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New query tab (⌘T)")
        }
        .frame(height: 28)
        .barBackground()
        .overlay(alignment: .bottom) { Divider() }
        .clipped()
    }
}

private struct TabButton: View {
    let tab: WorkspaceModel.Tab
    let selected: Bool
    let isPreview: Bool
    let select: () -> Void
    let pin: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let move: (Int) -> Void
    let canMove: (Int) -> Bool
    @State private var hovering = false

    private var background: Color {
        if selected {
            return Color(nsColor: .windowBackgroundColor)
        }
        if hovering {
            return Color.primary.opacity(0.04)
        }
        return .clear
    }

    private var icon: String {
        switch tab {
        case .table(let model): model.table.kind == .view ? "eye" : "tablecells"
        case .query: "chevron.left.forwardslash.chevron.right"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .metrics: "gauge.with.dots.needle.33percent"
        case .routine(let model): RoutineRow.symbol(model.routine?.kind ?? model.newKind)
        }
    }

    private var hasChanges: Bool {
        switch tab {
        case .table(let model): model.hasChanges
        case .query(let model): model.isEdited || model.hasResultChanges
        default: false
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(tab.title).font(.system(size: 12, weight: selected ? .medium : .regular)).italic(isPreview)
                    .lineLimit(1)
                if hasChanges {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 22)
            HStack {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
                        .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Close tab (⌘W)")
                .accessibilityLabel("Close \(tab.title)")
                Spacer()
            }
            .padding(.leading, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            background,
            ignoresSafeAreaEdges: []
        )
        .overlay(alignment: .top) {
            if selected {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        // One tap gesture selects at once; a separate double-tap gesture would hold every single click for the
        // double-click interval before selecting.
        .onTapGesture {
            select()
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                pin()
            }
        }
        .onHover { hovering = $0 }
        .help(isPreview ? "Preview tab — double-click to keep it open" : "")
        .contextMenu {
            if isPreview {
                Button("Keep Open", action: pin)
            }
            Button("Close Tab", action: close)
            Button("Close Other Tabs", action: closeOthers)
            Divider()
            Button("Move Tab Left") { move(-1) }
                .disabled(!canMove(-1))
            Button("Move Tab Right") { move(1) }
                .disabled(!canMove(1))
        }
    }
}
