import AppKit
import SwiftUI
import TabulaCore

/// Gives toolbar buttons access to the editor's current selection.
@MainActor
final class EditorHandle {
    weak var textView: NSTextView?

    var selectedText: String? {
        guard let textView else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    func focus() {
        textView?.window?.makeFirstResponder(textView)
    }

    /// The selection if there is one, otherwise the statement under the caret (briefly highlighted).
    func textToRun(kind: DatabaseKind) -> String? {
        if let selectedText { return selectedText }
        guard let textView else { return nil }
        let caret = textView.selectedRange().location
        guard let statement = SQLSplitter.statement(at: caret, in: textView.string, kind: kind) else { return nil }
        flash(statement.range)
        return statement.text
    }

    private func flash(_ range: NSRange) {
        guard let layoutManager = textView?.layoutManager else { return }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.22), forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.runFlash) { [weak layoutManager] in
            layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
    }

    /// Beautifies the selection, or the whole editor when nothing is selected. Undoable.
    func beautify(kind: DatabaseKind) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let range = selection.length > 0 ? selection : NSRange(location: 0, length: (textView.string as NSString).length)
        let original = (textView.string as NSString).substring(with: range)
        let formatted = SQLFormatter.format(original, kind: kind)
        guard formatted != original, textView.shouldChangeText(in: range, replacementString: formatted) else { return }
        textView.replaceCharacters(in: range, with: formatted)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: selection.length > 0 ? (formatted as NSString).length : 0))
    }
}

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var handle: EditorHandle
    /// Completions for the word at a caret (UTF-16 offset): the range they replace and the candidates, best first.
    var suggest: (_ text: String, _ caret: Int) -> (range: NSRange, items: [String])
    /// Changes when completion has learned new names; the editor then refreshes its suggestion.
    var completionVersion = 0
    /// Each query tab keeps its own undo history.
    var undoManager: UndoManager
    /// ⌘↩ runs the selection or current statement; ⇧⌘↩ runs everything.
    var onRun: (_ all: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SQLTextView.scrollableTextView()
        let textView = SQLTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        // macOS's own word completion and grey inline predictions are for prose; they would hide
        // (and fight with) the SQL suggestions.
        textView.isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) { textView.inlinePredictionType = .no }
        textView.font = SQLHighlighter.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        textView.string = text
        SQLHighlighter.highlight(textView)

        // Since macOS 14 views don't clip by default; the line-number gutter would draw over the bar above.
        scrollView.clipsToBounds = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        let ruler = LineNumberRuler(textView: textView)
        ruler.clipsToBounds = true
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        handle.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        handle.textView = textView
        if textView.string != text {
            textView.string = text
            SQLHighlighter.highlight(textView)
        }
        if context.coordinator.completionVersion != completionVersion {
            context.coordinator.completionVersion = completionVersion
            (textView as? SQLTextView)?.refreshInlineSuggestion()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        var completionVersion = 0
        init(_ parent: SQLEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SQLTextView else { return }
            SQLHighlighter.highlight(textView)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            parent.text = textView.string
            textView.updateInlineSuggestion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? SQLTextView)?.dropInlineSuggestionIfMoved()
        }

        /// The native completion list (⎋, ⌃Space).
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            parent.suggest(textView.string, NSMaxRange(charRange)).items
        }
    }
}

final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorView.Coordinator?

    /// Grey text after the caret completing the current word; Tab accepts it.
    private var inlineSuggestion: (location: Int, text: String)? {
        didSet { needsDisplay = true }
    }
    /// Set while text is being typed, so only typing (not deleting or pasting) offers a suggestion.
    private var typedCharacter = false
    /// Where the last typed character went; a late refresh (names finished loading) only applies there.
    private var lastTypedLocation: Int?

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        typedCharacter = text.count == 1
        super.insertText(string, replacementRange: replacementRange)
        lastTypedLocation = typedCharacter ? selectedRange().location : nil
        typedCharacter = false
    }

    func updateInlineSuggestion() {
        let caret = selectedRange()
        guard typedCharacter, caret.length == 0, let coordinator else { inlineSuggestion = nil; return }
        let (range, items) = coordinator.parent.suggest(string, caret.location)
        let partial = (string as NSString).substring(with: range)
        // Only complete at the end of a word, never in the middle of one.
        let nextIsWord = caret.location < (string as NSString).length
            && (string as NSString).substring(with: NSRange(location: caret.location, length: 1)).rangeOfCharacter(from: .alphanumerics) != nil
        // Right after "schema." or "alias." there is no word yet; the first table or column is offered as is.
        // (Not the completion list: NSTextView runs it modally, which would stall the app while it's open.)
        let afterDot = caret.location > 0 && (string as NSString).character(at: caret.location - 1) == UInt16(UInt8(ascii: "."))
        guard !partial.isEmpty || afterDot, !nextIsWord, let best = items.first, best.count > partial.count else { inlineSuggestion = nil; return }
        inlineSuggestion = (caret.location, String(best.dropFirst(partial.count)))
    }

    /// Recomputes the suggestion after table or column names arrive, if the caret is still where the user typed.
    func refreshInlineSuggestion() {
        guard inlineSuggestion == nil, let location = lastTypedLocation, selectedRange() == NSRange(location: location, length: 0) else { return }
        typedCharacter = true
        updateInlineSuggestion()
        typedCharacter = false
    }

    func dropInlineSuggestionIfMoved() {
        if let suggestion = inlineSuggestion, selectedRange() != NSRange(location: suggestion.location, length: 0) { inlineSuggestion = nil }
    }

    override func insertTab(_ sender: Any?) {
        guard let suggestion = inlineSuggestion else { return super.insertTab(sender) }
        inlineSuggestion = nil
        insertText(suggestion.text, replacementRange: NSRange(location: suggestion.location, length: 0))
    }

    override func cancelOperation(_ sender: Any?) {
        // ⎋ first dismisses the inline suggestion, then opens the completion list as usual.
        if inlineSuggestion != nil { inlineSuggestion = nil } else { super.cancelOperation(sender) }
    }

    /// The word the completion list replaces: what the SQL lexer considers the word at the caret, which
    /// is empty right after a dot (NSTextView's default would take the whole `alias.` text).
    override var rangeForUserCompletion: NSRange {
        coordinator?.parent.suggest(string, selectedRange().location).range ?? super.rangeForUserCompletion
    }

    override func complete(_ sender: Any?) {
        inlineSuggestion = nil
        super.complete(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let suggestion = inlineSuggestion, let layoutManager, let textContainer else { return }
        let length = (string as NSString).length
        let origin: NSPoint
        if suggestion.location >= length, length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: length - 1)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            // After a trailing newline the caret sits on the extra line fragment.
            let lastIsNewline = (string as NSString).character(at: length - 1) == 0x0A
            origin = lastIsNewline ? layoutManager.extraLineFragmentRect.origin : NSPoint(x: rect.maxX, y: rect.minY)
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: suggestion.location)
            origin = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 0), in: textContainer).origin
        }
        let point = NSPoint(x: origin.x + textContainerOrigin.x, y: origin.y + textContainerOrigin.y)
        (suggestion.text as NSString).draw(at: point, withAttributes: [.font: SQLHighlighter.font, .foregroundColor: NSColor.placeholderTextColor])
    }

    override var undoManager: UndoManager? {
        coordinator?.parent.undoManager ?? super.undoManager
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == KeyCode.return || event.keyCode == KeyCode.enter, flags == [.command] || flags == [.command, .shift] {
            coordinator?.parent.onRun(flags.contains(.shift))
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == [.command] || flags == [.command, .shift], let undo = undoManager {
            if flags.contains(.shift) { if undo.canRedo { undo.redo() } } else if undo.canUndo { undo.undo() }
            return true
        }
        if event.charactersIgnoringModifiers == "/" && flags == [.command] {
            toggleLineComments()
            return true
        }
        if event.keyCode == KeyCode.space && flags == [.control] {
            complete(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘/: comment or uncomment every line touched by the selection.
    func toggleLineComments() {
        let text = string as NSString
        let lines = text.lineRange(for: selectedRange())
        let block = text.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let hasTrailingNewline = parts.last == ""
        if hasTrailingNewline { parts.removeLast() }
        let nonEmpty = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let updated = parts.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allCommented, let range = line.range(of: "--") {
                var result = line
                let after = result.index(range.upperBound, offsetBy: 0)
                result.removeSubrange(range.lowerBound..<(result[after...].hasPrefix(" ") ? result.index(after: after) : after))
                return result
            }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            return indent + "-- " + line.dropFirst(indent.count)
        }
        let replacement = updated.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        if shouldChangeText(in: lines, replacementString: replacement) {
            replaceCharacters(in: lines, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length - (hasTrailingNewline ? 1 : 0)))
        }
    }

    // Keep the caret's indentation on newline.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// Gutter with line numbers for the SQL editor.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lineNumber = text.substring(to: characters.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let caretLine = text.substring(to: min(textView.selectedRange().location, text.length)).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let inset = textView.textContainerInset.height
        let relativeY = convert(NSPoint.zero, from: textView).y

        var index = characters.location
        func draw(_ number: Int, y: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: number == caretLine ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
        while index < NSMaxRange(characters) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            draw(lineNumber, y: relativeY + lineRect.minY + inset + (lineRect.height - font.capHeight - 6) / 2)
            lineNumber += 1
            index = NSMaxRange(lineRange)
        }
        // Empty last line after a trailing newline (or an empty document).
        if text.length == 0 || text.hasSuffix("\n"), NSMaxRange(characters) >= text.length {
            let extra = layoutManager.extraLineFragmentRect
            draw(lineNumber, y: relativeY + extra.minY + inset + (max(extra.height, 15) - font.capHeight - 6) / 2)
        }
    }
}

enum SQLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let maxHighlightedLength = 300_000

    static let keywords = SQLKeywords.all

    private static let patterns: [(NSRegularExpression, NSColor)] = {
        let keywordPattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        let rules: [(String, NSRegularExpression.Options, NSColor)] = [
            (keywordPattern, [.caseInsensitive], .systemPink),
            ("\\b\\d+(\\.\\d+)?\\b", [], .systemBlue),
            ("'(?:[^']|'')*'?", [], .systemOrange),
            ("\"(?:[^\"]|\"\")*\"?|`[^`]*`?", [], .systemTeal),
            ("--[^\n]*|#[^\n]*|/\\*[\\s\\S]*?(\\*/|$)", [], .systemGray),
        ]
        return rules.compactMap { pattern, options, color in
            (try? NSRegularExpression(pattern: pattern, options: options)).map { ($0, color) }
        }
    }()

    /// Recolors the whole document; later rules (strings, comments) win over earlier ones.
    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        // Past this size recoloring on every keystroke gets slow; large scripts stay plain.
        guard full.length < Self.maxHighlightedLength else {
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
            return
        }
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        for (regex, color) in patterns {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }
}
