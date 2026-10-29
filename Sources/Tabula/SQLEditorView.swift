import AppKit
import SwiftUI
import TabulaFoundation
import TabulaSQL

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
        // A tab kept hidden in the background must not take the keyboard from the one shown.
        guard let textView, !textView.isHiddenOrHasHiddenAncestor else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// The selection if there is one, otherwise the statement under the caret (briefly highlighted).
    func textToRun(dialect: any QueryDialect) -> String? {
        if let selectedText {
            return selectedText
        }
        guard let textView else { return nil }
        let caret = textView.selectedRange().location
        guard let statement = dialect.statement(at: caret, in: textView.string) else { return nil }
        flash(statement.range)
        return statement.text
    }

    private func flash(_ range: NSRange) {
        guard let layoutManager = textView?.layoutManager else { return }
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: NSColor.controlAccentColor.withAlphaComponent(0.22),
            forCharacterRange: range
        )
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
        if let textView, textView.string == snapshot.text {
            textView.setSelectedRange(snapshot.range)
        }
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
        guard range.location != NSNotFound else {
            return insertReplacingSelection(text)
        }
        replace(range, with: text)
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
    }

    private func replace(_ range: NSRange, with text: String) {
        guard let textView, textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        SQLHighlighter.highlight(textView)
    }

    /// Beautifies the selection, or the whole editor when nothing is selected. Undoable.
    func beautify(dialect: any QueryDialect) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let range =
            selection.length > 0 ? selection : NSRange(location: 0, length: (textView.string as NSString).length)
        let original = (textView.string as NSString).substring(with: range)
        let formatted = dialect.beautify(original)
        guard formatted != original, textView.shouldChangeText(in: range, replacementString: formatted) else { return }
        textView.replaceCharacters(in: range, with: formatted)
        textView.didChangeText()
        textView.setSelectedRange(
            NSRange(location: range.location, length: selection.length > 0 ? (formatted as NSString).length : 0)
        )
    }
}

struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    var handle: EditorHandle
    /// The language's comments, quoting and keywords, for highlighting (`#` comments on MySQL, `$$` strings on Postgres).
    var dialect: any QueryDialect
    /// Completions for the word at a caret (UTF-16 offset): the range they replace and the candidates, best first.
    var suggest: (_ text: String, _ caret: Int) -> (range: NSRange, items: [String])
    typealias AISuggest = @MainActor (_ before: String, _ after: String) async -> String?
    /// Asks a model for a continuation when the user pauses typing; nil when AI suggestions are off.
    var aiSuggest: AISuggest?
    /// Pause before asking: short for models on this Mac, longer for remote ones.
    var aiSuggestDelay: Double = Defaults.AI.inlineDelay
    /// Saved queries (#94): typing a keyword offers its query in the completion list (⌃Space), and choosing it
    /// inserts the SQL.
    var savedQueries: [SavedQuery] = []
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
        textView.dialect = dialect
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
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = .no
        }
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
        (textView as? SQLTextView)?.dialect = dialect
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

        /// The native completion list (⎋, ⌃Space): names and keywords, then saved queries whose keyword starts
        /// with the word typed.
        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let names = parent.suggest(textView.string, NSMaxRange(charRange)).items
            let partial = (textView.string as NSString).substring(with: charRange)
            let saved = parent.savedQueries.filter { query in
                query.keyword.range(of: partial, options: [.caseInsensitive, .anchored]) != nil
            }
            return names + saved.map(Self.label)
        }

        /// How a saved query reads in the completion list; never a name the database could have.
        static func label(_ query: SavedQuery) -> String {
            "\(query.keyword) — saved query"
        }

        func savedQuery(labelled label: String) -> SavedQuery? {
            parent.savedQueries.first { Self.label($0) == label }
        }
    }
}
