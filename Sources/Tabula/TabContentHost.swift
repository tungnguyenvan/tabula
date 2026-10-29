import AppKit
import SwiftUI

/// The open tabs' content, each kept for as long as its tab is open, as NSTabView keeps its items' views.
///
/// Switching tabs hides one view and shows another instead of building the next tab again: a query tab's editor,
/// split view and grid were created and laid out again on every switch, and lost their scroll position,
/// selection and caret. A tab's view still updates while hidden (a query keeps running and shows its results when
/// you come back), but hidden views aren't laid out or drawn.
struct TabContentHost: NSViewRepresentable {
    let tabs: [WorkspaceModel.Tab]
    let selectedID: UUID?
    /// Tabs whose view goes away when hidden, such as metrics, which poll the server only while shown.
    let transient: Set<UUID>
    let content: (WorkspaceModel.Tab) -> AnyView

    func makeNSView(context: Context) -> TabContainerView { TabContainerView() }

    func updateNSView(_ view: TabContainerView, context: Context) {
        view.update(tabs: tabs, selectedID: selectedID, transient: transient, content: content)
    }
}

final class TabContainerView: NSView {
    private var hosts: [UUID: NSHostingView<AnyView>] = [:]
    /// Where the keyboard focus was in each hidden tab, to put it back when the tab is shown again.
    private var focus: [UUID: WeakView] = [:]
    private var shown: UUID?

    private struct WeakView { weak var view: NSView? }

    func update(
        tabs: [WorkspaceModel.Tab],
        selectedID: UUID?,
        transient: Set<UUID>,
        content: (WorkspaceModel.Tab) -> AnyView
    ) {
        let open = Set(tabs.map(\.id))
        for (id, host) in hosts where !open.contains(id) {
            host.removeFromSuperview()
            hosts[id] = nil
            focus[id] = nil
            if shown == id { shown = nil }
        }
        let selected = selectedID.flatMap { id in tabs.first { $0.id == id } }
        if let shown, shown != selected?.id, let host = hosts[shown] {
            hide(host, id: shown)
            if transient.contains(shown) {
                host.removeFromSuperview()
                hosts[shown] = nil
            }
        }
        guard let selected else {
            shown = nil
            return
        }

        let host: NSHostingView<AnyView>
        if let existing = hosts[selected.id] {
            host = existing
            host.rootView = content(selected)
        } else {
            host = NSHostingView(rootView: content(selected))
            // The container sets the frame; no size constraints or safe areas from SwiftUI.
            host.sizingOptions = []
            host.safeAreaRegions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            hosts[selected.id] = host
        }
        guard shown != selected.id else { return }
        shown = selected.id
        host.isHidden = false
        // Back where the keyboard was in this tab; otherwise in its SQL editor, as a newly opened query tab is.
        if let view = focus[selected.id]?.view, view.isDescendant(of: host) {
            window?.makeFirstResponder(view)
        } else if let editor = Self.first(SQLTextView.self, in: host) {
            window?.makeFirstResponder(editor)
        }
    }

    private func hide(_ host: NSHostingView<AnyView>, id: UUID) {
        // A hidden view must not keep the keyboard: typing would go into a tab that isn't shown.
        if let window, var responder = window.firstResponder as? NSView, responder.isDescendant(of: host) {
            // Text fields and cell editors type through the window's field editor; remember the control itself.
            if let editor = responder as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
                responder = control
            }
            focus[id] = WeakView(view: responder)
            if !window.makeFirstResponder(nil) {
                window.endEditing(for: nil)
                window.makeFirstResponder(nil)
            }
        }
        host.isHidden = true
    }

    /// Shortcuts go to the tab shown only; hidden tabs' buttons (Apply, Send) must not answer Return.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let shown, let host = hosts[shown] else { return false }
        return host.performKeyEquivalent(with: event)
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews where !subview.isHidden {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }
}
