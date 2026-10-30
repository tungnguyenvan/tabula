import Foundation

/// How the sidebar, the connection list and the command palette compare names with what is typed: without case,
/// accents or width, so "khach" finds "khách_hàng". Đ has no accent to Foundation, so it becomes D here.
enum SearchText {
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }

    static func matches(_ text: String, _ search: String) -> Bool {
        folded(text).contains(folded(search))
    }
}
