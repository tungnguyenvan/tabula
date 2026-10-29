import AppKit
import SwiftUI
import TabulaFoundation
import TabulaSQL

final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorView.Coordinator?
    /// Set by the editor view before the text view shows any text.
    var dialect: (any QueryDialect)?

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
        guard typedCharacter, caret.length == 0, let coordinator else {
            inlineSuggestion = nil
            return
        }
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
        let nextIsWord =
            caret.location < (string as NSString).length
            && (string as NSString).substring(with: NSRange(location: caret.location, length: 1))
                .rangeOfCharacter(from: .alphanumerics) != nil
        // Right after "schema." or "alias." there is no word yet; the first table or column is offered as is.
        // (Not the completion list: NSTextView runs it modally, which would stall the app while it's open.)
        let afterDot =
            caret.location > 0 && (string as NSString).character(at: caret.location - 1) == UInt16(UInt8(ascii: "."))
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
        let nextIsWord =
            location < full.length
            && full.substring(with: NSRange(location: location, length: 1)).rangeOfCharacter(from: .alphanumerics)
                != nil
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
                self.selectedRange() == NSRange(location: location, length: 0)
            else { return }
            self.lastAnswer = (text, location, suggestion)
            self.inlineSuggestion = (location, suggestion)
        }
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Any edit other than typing (delete, paste, undo) cancels a pending late refresh.
        if !typedCharacter {
            lastTypedLocation = nil
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    /// Recomputes the suggestion after table or column names arrive, if the caret is still where the user typed.
    func refreshInlineSuggestion() {
        guard inlineSuggestion == nil, let location = lastTypedLocation,
            selectedRange() == NSRange(location: location, length: 0)
        else { return }
        typedCharacter = true
        updateInlineSuggestion()
        typedCharacter = false
    }

    func dropInlineSuggestionIfMoved() {
        // Moving the caret away from where the user typed cancels a pending AI request.
        if selectedRange() != NSRange(location: lastTypedLocation ?? -1, length: 0) {
            aiTask?.cancel()
        }
        if let suggestion = inlineSuggestion, selectedRange() != NSRange(location: suggestion.location, length: 0) {
            inlineSuggestion = nil
        }
    }

    override func insertTab(_ sender: Any?) {
        guard let suggestion = inlineSuggestion else {
            return super.insertTab(sender)
        }
        inlineSuggestion = nil
        insertText(suggestion.text, replacementRange: NSRange(location: suggestion.location, length: 0))
    }

    override func cancelOperation(_ sender: Any?) {
        // ⎋ first dismisses the inline suggestion, then opens the completion list as usual.
        if inlineSuggestion != nil {
            inlineSuggestion = nil
        } else {
            super.cancelOperation(sender)
        }
    }

    /// The word the completion list replaces: what the SQL lexer considers the word at the caret, which
    /// is empty right after a dot (NSTextView's default would take the whole `alias.` text).
    override var rangeForUserCompletion: NSRange {
        coordinator?.parent.suggest(string, selectedRange().location).range ?? super.rangeForUserCompletion
    }

    #if DEBUG
    /// What choosing the first saved query in the completion list does (for scripted checks).
    func completeFirstSavedQuery() {
        guard let coordinator else { return }
        let range = rangeForUserCompletion
        var index = 0
        let items = coordinator.textView(self, completions: [], forPartialWordRange: range, indexOfSelectedItem: &index)
        guard let label = items.first(where: { coordinator.savedQuery(labelled: $0) != nil }) else {
            print("COMPLETE no saved query offered")
            return
        }
        insertCompletion(label, forPartialWordRange: range, movement: NSReturnTextMovement, isFinal: true)
        print("COMPLETE", label)
    }
    #endif

    /// A saved query shows as its keyword while the list is browsed, and becomes its SQL once chosen.
    override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        guard let saved = coordinator?.savedQuery(labelled: word) else {
            return super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        }
        let text = flag ? saved.sql : saved.keyword
        super.insertCompletion(text, forPartialWordRange: charRange, movement: movement, isFinal: flag)
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
            origin =
                layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 0), in: textContainer).origin
        }
        let point = NSPoint(x: origin.x + textContainerOrigin.x, y: origin.y + textContainerOrigin.y)
        (suggestion.text as NSString)
            .draw(
                at: point,
                withAttributes: [.font: SQLHighlighter.font, .foregroundColor: NSColor.placeholderTextColor]
            )
    }

    override var undoManager: UndoManager? {
        coordinator?.parent.undoManager ?? super.undoManager
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == KeyCode.return || event.keyCode == KeyCode.enter,
            flags == [.command] || flags == [.command, .shift]
        {
            coordinator?.parent.onRun(flags.contains(.shift))
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "z", flags == [.command] || flags == [.command, .shift],
            let undo = undoManager
        {
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
            if coordinator?.parent.onStop?() == true {
                return true
            }
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
        if hasTrailingNewline {
            parts.removeLast()
        }
        let nonEmpty = parts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented =
            !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
        let updated = parts.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                return line
            }
            if allCommented, let range = line.range(of: "--") {
                var result = line
                let after = result.index(range.upperBound, offsetBy: 0)
                result.removeSubrange(
                    range.lowerBound..<(result[after...].hasPrefix(" ") ? result.index(after: after) : after)
                )
                return result
            }
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            return indent + "-- " + line.dropFirst(indent.count)
        }
        let replacement = updated.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        if shouldChangeText(in: lines, replacementString: replacement) {
            replaceCharacters(in: lines, with: replacement)
            didChangeText()
            setSelectedRange(
                NSRange(
                    location: lines.location,
                    length: (replacement as NSString).length - (hasTrailingNewline ? 1 : 0)
                )
            )
        }
    }

    // Keep the caret's indentation on newline.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(indent, replacementRange: selectedRange())
        }
    }
}
