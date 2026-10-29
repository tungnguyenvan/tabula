import AppKit
import SwiftUI
import TabulaFoundation
import TabulaSQL

/// Gutter with line numbers for the SQL editor.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(redraw),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return
        }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let text = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lineNumber = text.substring(to: characters.location).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let caretLine = text.substring(to: min(textView.selectedRange().location, text.length))
            .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
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

/// Colors an editor's text; runs with the editor, on the main actor.
@MainActor
enum SQLHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let maxHighlightedLength = 300_000

    static let keywords = SQLKeywords.all

    /// Colors by token kind, from the same lexer the formatter and completion use, so an apostrophe
    /// in a comment can't start a "string" that runs on through the next lines.
    private static func color(for token: SQLToken, dialect: any QueryDialect) -> NSColor? {
        switch token.kind {
        case .word:
            switch dialect.role(ofWord: token) {
            case .keyword: return .systemPink
            case .operator: return .systemPurple
            case nil: return nil
            }
        case .number: return .systemBlue
        case .string: return .systemOrange
        case .quotedIdentifier: return .systemTeal
        case .comment: return .systemGray
        case .whitespace, .punctuation: return nil
        }
    }

    /// Recolors the whole document, in the language of the editor it belongs to.
    static func highlight(_ textView: NSTextView) {
        guard let storage = textView.textStorage, let dialect = (textView as? SQLTextView)?.dialect else { return }
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        // Past this size recoloring on every keystroke gets slow; large scripts stay plain.
        guard full.length < Self.maxHighlightedLength else {
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
            return
        }
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
        for token in dialect.tokens(text) {
            if let color = color(for: token, dialect: dialect) {
                storage.addAttribute(.foregroundColor, value: color, range: token.range)
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }
}
