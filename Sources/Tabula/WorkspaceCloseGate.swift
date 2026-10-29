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

    // NSObject declares these nonisolated; AppKit only asks a window's delegate on the main thread.
    override nonisolated func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) {
            return true
        }
        return MainActor.assumeIsolated {
            original?.responds(to: selector) == true
        }
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        // Read and handed back on the main thread, where AppKit asks.
        nonisolated(unsafe) var forwarded: (any NSWindowDelegate)?
        MainActor.assumeIsolated {
            if let original, original.responds(to: selector) {
                forwarded = original
            }
        }
        if let forwarded {
            return forwarded
        }
        return super.forwardingTarget(for: selector)
    }
}
