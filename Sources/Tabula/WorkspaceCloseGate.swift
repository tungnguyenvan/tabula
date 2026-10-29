import AppKit

/// Adds a close veto for staged result edits while forwarding the rest of NSWindowDelegate to SwiftUI's delegate.
/// Replacing SwiftUI's delegate outright would break its window management and restoration behaviour.
@MainActor
final class WorkspaceCloseGate: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    private weak var session: ConnectionSession?
    private weak var original: (any NSWindowDelegate)?

    init(window: NSWindow, session: ConnectionSession) {
        self.window = window
        self.session = session
        self.original = window.delegate
    }

    func install() {
        guard let window, window.delegate !== self else { return }
        original = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard session?.confirmCloseResults() != false else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true {
            return original
        }
        return super.forwardingTarget(for: selector)
    }
}
