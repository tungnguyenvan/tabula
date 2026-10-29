import AppKit
import SwiftUI

/// A top/bottom pair with a draggable divider, built on AppKit's split view controller.
///
/// SwiftUI's `VSplitView` asks for new constraints every time its panes are laid out. Next to the window's
/// inspector (itself a split view) the two kept invalidating each other until AppKit stopped the app
/// ("more Update Constraints in Window passes than there are views in the window"). Here the panes are hosting
/// controllers that don't publish sizes as constraints, so the split view alone decides their frames.
///
/// Keep it below other content rather than at the very top of a window with a toolbar: the hosted panes ignore
/// the window's safe areas, so a top pane there would sit under the toolbar.
struct VerticalSplit<Top: View, Bottom: View>: NSViewControllerRepresentable {
    private let top: Top
    private let bottom: Bottom
    private let topMinimum: CGFloat
    private let bottomMinimum: CGFloat
    /// Height the top (or bottom) pane starts at, the first time; afterwards the divider position is remembered.
    private let topIdeal: CGFloat?
    private let bottomIdeal: CGFloat?
    /// The pane that takes extra height when the window grows.
    private let growing: Grow

    enum Grow { case top, bottom }

    /// A pane's content in the frame the split view gives it. A pane dragged smaller than its content keeps the
    /// top (the bar with the pane's controls) and loses the bottom, rather than SwiftUI centering the overflow.
    struct Pane<Content: View>: View {
        let content: Content
        var body: some View {
            GeometryReader { geometry in
                content.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
            }
        }
    }
    /// The divider position is saved under this name, as macOS does for split views.
    private let autosaveName: String?

    init(
        topMinimum: CGFloat,
        bottomMinimum: CGFloat,
        topIdeal: CGFloat? = nil,
        bottomIdeal: CGFloat? = nil,
        growing: Grow = .bottom,
        autosaveName: String? = nil,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.top = top()
        self.bottom = bottom()
        self.topMinimum = topMinimum
        self.bottomMinimum = bottomMinimum
        self.topIdeal = topIdeal
        self.bottomIdeal = bottomIdeal
        self.growing = growing
        self.autosaveName = autosaveName
    }

    func makeNSViewController(context: Context) -> SplitController {
        let controller = SplitController(topIdeal: topIdeal, bottomIdeal: bottomIdeal)
        controller.splitView.isVertical = false
        controller.splitView.dividerStyle = .thin
        let topItem = NSSplitViewItem(viewController: Self.host(top))
        topItem.minimumThickness = topMinimum
        let bottomItem = NSSplitViewItem(viewController: Self.host(bottom))
        bottomItem.minimumThickness = bottomMinimum
        // The pane that holds its height more firmly keeps it when the window is resized.
        (growing == .bottom ? topItem : bottomItem).holdingPriority = .defaultLow + 1
        controller.addSplitViewItem(topItem)
        controller.addSplitViewItem(bottomItem)
        if let autosaveName {
            controller.splitView.autosaveName = autosaveName
        }
        return controller
    }

    func updateNSViewController(_ controller: SplitController, context: Context) {
        (controller.splitViewItems[0].viewController.view as? NSHostingView<Pane<Top>>)?.rootView = Pane(content: top)
        (controller.splitViewItems[1].viewController.view as? NSHostingView<Pane<Bottom>>)?.rootView = Pane(
            content: bottom
        )
        controller.splitViewItems[0].minimumThickness = topMinimum
        controller.splitViewItems[1].minimumThickness = bottomMinimum
    }

    private static func host<Content: View>(_ content: Content) -> NSViewController {
        let view = NSHostingView(rootView: Pane(content: content))
        // No size constraints from SwiftUI: the split view sets the pane's frame.
        view.sizingOptions = []
        // The pane lies below the toolbar; window safe areas would only shift its content.
        view.safeAreaRegions = []
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    /// Puts the divider at the ideal height once, when there is no saved position.
    final class SplitController: NSSplitViewController {
        private let topIdeal: CGFloat?
        private let bottomIdeal: CGFloat?
        private var placed = false

        init(topIdeal: CGFloat?, bottomIdeal: CGFloat?) {
            self.topIdeal = topIdeal
            self.bottomIdeal = bottomIdeal
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLayout() {
            super.viewDidLayout()
            guard !placed, splitView.bounds.height > 0 else { return }
            placed = true
            let saved =
                splitView.autosaveName.map {
                    UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") != nil
                } ?? false
            guard !saved else { return }
            let position = topIdeal ?? bottomIdeal.map { splitView.bounds.height - $0 - splitView.dividerThickness }
            if let position {
                DispatchQueue.main.async { self.splitView.setPosition(position, ofDividerAt: 0) }
            }
        }
    }
}
