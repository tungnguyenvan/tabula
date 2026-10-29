import AppKit
import SwiftUI

/// App-modal confirmation, used before anything that throws away work or data.
@MainActor
enum Confirmation {
    static func ask(_ message: String, detail: String, action: String, style: NSAlert.Style = .warning) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = style
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Reports a failed user action (saving a file, exporting) that has no other place to show an error.
    static func report(_ message: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

@MainActor
enum Clipboard {
    /// `pasteboard` is the system one, except in tests.
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Empty space that moves the window when dragged, for panes without a title bar above them.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
