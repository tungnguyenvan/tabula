import SwiftUI

/// Design tokens: every size, spacing and font the views share. Change a value here, not in a view.
enum Layout {
    static let cornerRadius: CGFloat = 6
    static let statusDot: CGFloat = 7
    /// Height of the filter, tab and status bars.
    static let barHeight: CGFloat = 28
    static let barPadding: CGFloat = 8

    enum Font {
        /// Bars, captions and secondary labels.
        static let small = SwiftUI.Font.system(size: 11)
        static let smallBold = SwiftUI.Font.system(size: 11, weight: .semibold)
        /// Body text in lists and tabs.
        static let body = SwiftUI.Font.system(size: 12)
        static let bodyBold = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 13, weight: .medium)
        /// Values, SQL and keys.
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let icon = SwiftUI.Font.system(size: 10)
        static let tag = SwiftUI.Font.system(size: 9, weight: .heavy)
        /// Large symbol on empty and error states.
        static let placeholderSymbol = SwiftUI.Font.system(size: 34, weight: .light)
    }

    enum Tabs {
        /// Tabs share the bar, each between these widths; past that the bar scrolls.
        static let minWidth: CGFloat = 120
        static let maxWidth: CGFloat = 220
        static let separatorHeight: CGFloat = 14
        static let selectionLine: CGFloat = 2
        static let closeButton: CGFloat = 16
        static let titlePadding: CGFloat = 22
        static let addButtonWidth: CGFloat = 28
    }

    enum Filter {
        static let conjunctionWidth: CGFloat = 64
        static let columnWidth: CGFloat = 170
        static let operatorWidth: CGFloat = 120
    }

    /// Split views take a pane's ideal width as its minimum, so every pane says `minWidth: 0`.
    enum Query {
        static let editorMinHeight: CGFloat = 120
        static let editorIdealHeight: CGFloat = 260
        static let resultsMinHeight: CGFloat = 140
    }

    enum Redis {
        static let keysMinHeight: CGFloat = 180
        static let keysIdealHeight: CGFloat = 380
        static let valueMinHeight: CGFloat = 160
        static let valueIdealHeight: CGFloat = 320
    }

    enum Console {
        static let minHeight: CGFloat = 90
        static let idealHeight: CGFloat = 180
        static let rowHeight: CGFloat = 20
    }

    enum Welcome {
        static let width: CGFloat = 250
    }

    enum Rail {
        static let width: CGFloat = 48
        static let itemSize: CGFloat = 34
        static let badgeSize: CGFloat = 24
        static let tagWidth: CGFloat = 3
        static let spacing: CGFloat = 6
        static let addFont = SwiftUI.Font.system(size: 12, weight: .medium)
    }

    enum Pill {
        static let minWidth: CGFloat = 320
        static let maxWidth: CGFloat = 560
        static let height: CGFloat = 26
        static let badgeSize: CGFloat = 18
    }

    enum Sidebar {
        static let minWidth: CGFloat = 180
        static let idealWidth: CGFloat = 230
        static let maxWidth: CGFloat = 400
    }

    enum Inspector {
        static let minWidth: CGFloat = 240
        static let idealWidth: CGFloat = 300
        static let maxWidth: CGFloat = 520
    }

    enum Window {
        static let workspace = CGSize(width: 1280, height: 800)
        static let connections = CGSize(width: 760, height: 480)
        static let shortcuts = CGSize(width: 760, height: 620)
    }
}

/// Timings for UI feedback.
enum Timing {
    /// How long the editor highlights the statement that just ran.
    static let runFlash: Double = 0.45
    static let tabScroll: Double = 0.15
}
