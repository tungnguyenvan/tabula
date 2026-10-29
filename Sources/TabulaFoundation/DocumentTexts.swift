import Foundation

/// The documents behind a result's rows, as shell text, written only when asked for (an edit, the document
/// editor): writing every document of a large page up front cost as much as making its cells.
public struct DocumentTexts: RandomAccessCollection, Sendable {
    private let documentCount: Int
    private let text: @Sendable (Int) -> String

    /// `text` writes the document at a row as shell text.
    public init(count: Int, text: @escaping @Sendable (Int) -> String) {
        self.documentCount = count
        self.text = text
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { documentCount }

    public subscript(position: Int) -> String {
        precondition(indices.contains(position), "No document at row \(position).")
        return text(position)
    }
}
