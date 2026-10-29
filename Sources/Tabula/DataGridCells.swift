import AppKit
import SwiftUI

final class GridTableView: NSTableView {
    weak var coordinator: DataGridView.Coordinator?

    override var undoManager: UndoManager? {
        coordinator?.parent.undoManager ?? super.undoManager
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    /// A double-click in the empty space below the rows adds a row. Table views send no double action
    /// there, so it is caught here.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onAddRow = coordinator?.parent.onAddRow,
            row(at: convert(event.locationInWindow, from: nil)) < 0
        {
            onAddRow()
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let coordinator else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("z", [.command]):
            // Undo/redo the grid's own (per-tab) history directly; the menu item targets the window's manager.
            if let undo = undoManager, undo.canUndo {
                undo.undo()
            }
            return true
        case ("z", [.command, .shift]):
            if let undo = undoManager, undo.canRedo {
                undo.redo()
            }
            return true
        case ("c", [.command, .option]):
            coordinator.copyFocusedCell()
            return true
        case ("c", [.command, .option, .shift]):
            coordinator.copySelection(withHeader: true)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else {
            return super.keyDown(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 123 where flags.contains(.command), 115:  // ⌘← / Home: first column
            coordinator.moveFocus(toColumn: 1)
        case 124 where flags.contains(.command), 119:  // ⌘→ / End: last column
            coordinator.moveFocus(toColumn: numberOfColumns - 1)
        case 126 where flags.contains(.command):  // ⌘↑: first row
            if numberOfRows > 0 {
                coordinator.focus(row: 0, tableColumn: coordinator.focusedColumn, edit: false)
            }
        case 125 where flags.contains(.command):  // ⌘↓: last row
            if numberOfRows > 0 {
                coordinator.focus(row: numberOfRows - 1, tableColumn: coordinator.focusedColumn, edit: false)
            }
        case 123:  // ←
            coordinator.moveFocus(toColumn: coordinator.focusedColumn - 1)
        case 124:  // →
            coordinator.moveFocus(toColumn: coordinator.focusedColumn + 1)
        case 48:  // Tab / ⇧Tab
            coordinator.advance(by: flags.contains(.shift) ? -1 : 1, edit: false)
        case 36, 76, 120:  // Return, Enter, F2
            guard flags.isEmpty else {
                return super.keyDown(with: event)
            }
            if coordinator.canEditFocusedCell {
                coordinator.beginEditing(row: selectedRow, column: coordinator.focusedColumn)
            } else {
                coordinator.showQuickLook()
            }
        case 49 where flags.isEmpty:  // Space
            coordinator.showQuickLook()
        case 51, 117:  // ⌫ / ⌦
            if flags.contains(.option) {
                coordinator.setFocusedCellNull()
            } else {
                coordinator.deleteSelection()
            }
        case 53:  // Escape
            deselectAll(nil)
        default:
            // Typing a character starts editing the focused cell with that character.
            if flags.subtracting(.shift).isEmpty, let characters = event.characters, !characters.isEmpty,
                characters.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700
                }),
                coordinator.canEditFocusedCell
            {
                coordinator.beginEditing(row: selectedRow, column: coordinator.focusedColumn, replacingWith: characters)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.menu(row: row(at: point), column: column(at: point))
    }
}

final class GridCellView: NSTableCellView {
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let placeholderFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

    /// Draws the keyboard-focus ring around the current cell.
    var isFocusedCell = false {
        didSet {
            layer?.borderWidth = isFocusedCell ? 1.5 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let field = NSTextField(labelWithString: "")
        field.font = Self.font
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isEditable = false
        field.focusRingType = .none
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ cell: GridCell, state: GridCellState) {
        guard let field = textField else { return }
        field.isEditable = false
        field.drawsBackground = false
        field.isBordered = false
        switch cell {
        case .value(let text):
            let singleLine = text.count > 2000 ? String(text.prefix(2000)) + "…" : text
            field.stringValue = singleLine.replacingOccurrences(of: "\r\n", with: " ⏎ ")
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            field.font = Self.font
            field.textColor = .labelColor
            field.toolTip = text.count > 40 ? String(text.prefix(1000)) : nil
        case .null:
            field.stringValue = "NULL"
            field.font = Self.placeholderFont
            field.textColor = .tertiaryLabelColor
            field.toolTip = nil
        case .defaultValue:
            field.stringValue = "DEFAULT"
            field.font = Self.placeholderFont
            field.textColor = .tertiaryLabelColor
            field.toolTip = nil
        }
        if state == .deleted {
            field.attributedStringValue = NSAttributedString(
                string: field.stringValue,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .font: field.font ?? Self.font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }
        layer?.backgroundColor =
            switch state {
            case .normal: nil
            case .edited: NSColor.systemYellow.withAlphaComponent(0.28).cgColor
            case .deleted: NSColor.systemRed.withAlphaComponent(0.18).cgColor
            case .inserted: NSColor.systemGreen.withAlphaComponent(0.18).cgColor
            }
    }

    func beginEditingAppearance() {
        guard let field = textField else { return }
        field.font = Self.font
        field.textColor = .labelColor
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
    }
}

final class GutterCellView: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        field.textColor = .tertiaryLabelColor
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Read-only, selectable view of a full cell value.
final class ValuePopoverController: NSViewController {
    private let titleText: String
    private let text: String

    init(title: String, text: String) {
        self.titleText = title
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.string = text
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyValue))
        copy.controlSize = .small
        let header = NSStackView(views: [title, NSView(), copy])
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        let lines = CGFloat(min(max(text.components(separatedBy: "\n").count, 3), 24))
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: lines * 16 + 60)
        view = stack
    }

    @objc private func copyValue() {
        Clipboard.copy(text)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    /// `key` is shown for discoverability; the real shortcut is handled by the grid or the menu bar.
    init(
        _ title: String,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
