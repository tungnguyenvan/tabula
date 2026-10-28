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

    /// The editor's selection and text at one moment, to insert an answer where it was asked for.
    struct Snapshot {
        var range: NSRange
        var text: String
        var selectedText: String? { range.length > 0 ? (text as NSString).substring(with: range) : nil }
    }

    func snapshot() -> Snapshot {
        Snapshot(range: textView?.selectedRange() ?? NSRange(location: 0, length: 0), text: textView?.string ?? "")
    }

    /// Inserts at the snapshot's selection if the text hasn't changed since, otherwise at the current one.
    func insert(_ text: String, at snapshot: Snapshot) {
        if let textView, textView.string == snapshot.text { textView.setSelectedRange(snapshot.range) }
        insertReplacingSelection(text)
    }

    /// Replaces the selection with `text`, or inserts it on its own line at the caret. Undoable.
    func insertReplacingSelection(_ text: String) {
        guard let textView else { return }
        var range = textView.selectedRange()
        var insertion = text
        let string = textView.string as NSString
        if range.length == 0, string.length > 0 {
            // Put generated SQL on a line of its own rather than in the middle of the current one.
            let line = string.lineRange(for: NSRange(location: range.location, length: 0))
            let lineText = string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !lineText.isEmpty {
                range = NSRange(location: NSMaxRange(line), length: 0)
                insertion = (string.substring(with: line).hasSuffix("\n") ? "" : "\n") + text + "\n"
            }
        }
        replace(range, with: insertion)
        textView.setSelectedRange(NSRange(location: range.location, length: (insertion as NSString).length))
    }

    /// Replaces the first occurrence of `original` (e.g. the statement that failed) with `text`;
    /// inserts `text` when `original` is no longer in the editor. Undoable.
    func replace(_ original: String, with text: String) {
        guard let textView else { return }
        let range = (textView.string as NSString).range(of: original)
        guard range.location != NSNotFound else { return insertReplacingSelection(text) }
        replace(range, with: text)
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
    }

    private func replace(_ range: NSRange, with text: String) {
        guard let textView, textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        SQLHighlighter.highlight(textView, kind: (textView as? SQLTextView)?.kind ?? .postgres)
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
    /// Decides comment and quoting rules for highlighting (`#` comments on MySQL, `$$` strings on Postgres).
    var kind: DatabaseKind
    /// Completions for the word at a caret (UTF-16 offset): the range they replace and the candidates, best first.
    var suggest: (_ text: String, _ caret: Int) -> (range: NSRange, items: [String])
    typealias AISuggest = @MainActor (_ before: String, _ after: String) async -> String?
    /// Asks a model for a continuation when the user pauses typing; nil when AI suggestions are off.
    var aiSuggest: AISuggest?
    /// Pause before asking: short for models on this Mac, longer for remote ones.
    var aiSuggestDelay: Double = Defaults.AI.inlineDelay
    /// Changes when completion has learned new names; the editor then refreshes its suggestion.
    var completionVersion = 0
    /// Each query tab keeps its own undo history.
    var undoManager: UndoManager
    /// ⌘↩ runs the selection or current statement; ⇧⌘↩ runs everything.
    var onRun: (_ all: Bool) -> Void
    /// Return true when a running query takes ⌘., instead of NSTextView's cancel action.
    var onStop: (() -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SQLTextView.scrollableTextView()
        let textView = SQLTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.kind = kind
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
        SQLHighlighter.highlight(textView, kind: (textView as? SQLTextView)?.kind ?? .postgres)

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
            SQLHighlighter.highlight(textView, kind: (textView as? SQLTextView)?.kind ?? .postgres)
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
            SQLHighlighter.highlight(textView, kind: (textView as? SQLTextView)?.kind ?? .postgres)
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
    var kind: DatabaseKind = .postgres

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
        aiTask?.cancel()
        let caret = selectedRange()
        guard typedCharacter, caret.length == 0, let coordinator else { inlineSuggestion = nil; return }
        // With AI suggestions on, the grey text comes from the model only; the completion list (⎋) still
        // offers tables, columns and keywords.
        if coordinator.parent.aiSuggest != nil {
            inlineSuggestion = nil
            scheduleAISuggestion()
            return
        }
        let (range, items) = coordinator.parent.suggest(string, caret.location)
        let partial = (string as NSString).substring(with: range)
        // Only complete at the end of a word, never in the middle of one.
        let nextIsWord = caret.location < (string as NSString).length
            && (string as NSString).substring(with: NSRange(location: caret.location, length: 1)).rangeOfCharacter(from: .alphanumerics) != nil
        // Right after "schema." or "alias." there is no word yet; the first table or column is offered as is.
        // (Not the completion list: NSTextView runs it modally, which would stall the app while it's open.)
        let afterDot = caret.location > 0 && (string as NSString).character(at: caret.location - 1) == UInt16(UInt8(ascii: "."))
        guard !partial.isEmpty || afterDot, !nextIsWord, let best = items.first, best.count > partial.count else {
            inlineSuggestion = nil
            return
        }
        inlineSuggestion = (caret.location, String(best.dropFirst(partial.count)))
    }

    private var aiTask: Task<Void, Never>?

    /// The last answer, so returning to the same text and caret (e.g. typing then deleting a character)
    /// shows it again without asking.
    private var lastAnswer: (text: String, location: Int, suggestion: String)?

    /// Asks the model once typing pauses. Any keystroke or caret move cancels it, and the answer is only
    /// shown if the text and caret are exactly as they were. Not in the middle of a word.
    private func scheduleAISuggestion() {
        guard let parent = coordinator?.parent, let ai = parent.aiSuggest else { return }
        let location = selectedRange().location
        let text = string
        let full = text as NSString
        let nextIsWord = location < full.length
            && full.substring(with: NSRange(location: location, length: 1)).rangeOfCharacter(from: .alphanumerics) != nil
        guard !nextIsWord else { return }
        if let lastAnswer, lastAnswer.text == text, lastAnswer.location == location {
            inlineSuggestion = (location, lastAnswer.suggestion)
            return
        }
        let delay = parent.aiSuggestDelay
        aiTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let suggestion = await ai(full.substring(to: location), full.substring(from: location))
            guard let self, !Task.isCancelled, let suggestion, self.string == text,
                  self.selectedRange() == NSRange(location: location, length: 0) else { return }
            self.lastAnswer = (text, location, suggestion)
            self.inlineSuggestion = (location, suggestion)
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Any edit other than typing (delete, paste, undo) cancels a pending late refresh.
        if !typedCharacter { lastTypedLocation = nil }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// Recomputes the suggestion after table or column names arrive, if the caret is still where the user typed.
    func refreshInlineSuggestion() {
        guard inlineSuggestion == nil, let location = lastTypedLocation, selectedRange() == NSRange(location: location, length: 0) else { return }
        typedCharacter = true
        updateInlineSuggestion()
        typedCharacter = false
    }

    func dropInlineSuggestionIfMoved() {
        // Moving the caret away from where the user typed cancels a pending AI request.
        if selectedRange() != NSRange(location: lastTypedLocation ?? -1, length: 0) { aiTask?.cancel() }
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
        // ⌘. is the text view's cancel; while a query runs it belongs to Query › Stop Query.
        if event.charactersIgnoringModifiers == "." && flags == [.command] {
            if coordinator?.parent.onStop?() == true { return true }
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

    /// Colors by token kind, from the same lexer the formatter and completion use, so an apostrophe
    /// in a comment can't start a "string" that runs on through the next lines.
    private static func color(for token: SQLToken, kind: DatabaseKind) -> NSColor? {
        switch token.kind {
        case .word where kind.isDocument:
            if token.text.hasPrefix("$") { return .systemPurple }
            return MongoVocabulary.highlighted.contains(token.text) ? .systemPink : nil
        case .word: return SQLKeywords.set.contains(token.keyword) ? .systemPink : nil
        case .number: return .systemBlue
        case .string: return .systemOrange
        case .quotedIdentifier: return .systemTeal
        case .comment: return .systemGray
        case .whitespace, .punctuation: return nil
        }
    }

    /// Recolors the whole document.
    static func highlight(_ textView: NSTextView, kind: DatabaseKind) {
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
        for token in SQLLexer.tokens(text, kind: kind) {
            if let color = color(for: token, kind: kind) { storage.addAttribute(.foregroundColor, value: color, range: token.range) }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }
}
