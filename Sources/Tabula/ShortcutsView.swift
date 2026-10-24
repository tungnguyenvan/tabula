import SwiftUI

/// Every keyboard shortcut, grouped by where it applies. Help ▸ Keyboard Shortcuts (⇧⌘/).
struct ShortcutsView: View {
    struct Group: Identifiable {
        let title: String
        let items: [(keys: String, action: String)]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Tabs & windows", items: [
            ("⌘T", "New query tab"),
            ("⌘W", "Close tab (window when no tabs)"),
            ("⇧⌘T", "Reopen closed tab"),
            ("⌘1 … ⌘8, ⌘9", "Go to tab / last tab"),
            ("⌃Tab  ⇧⌘]", "Next tab"),
            ("⌃⇧Tab  ⇧⌘[", "Previous tab"),
            ("⌘P", "Open anything (tables, tabs, actions)"),
            ("⇧⌘K", "Connections"),
        ]),
        Group(title: "Browsing", items: [
            ("⌥⌘F", "Filter the table list"),
            ("↑ ↓ in sidebar", "Preview table (reuses one tab)"),
            ("↩ / double-click", "Open table in its own tab"),
            ("⌥⌘1 / ⌥⌘2", "Data / Structure"),
            ("⌘F", "Filter rows (again to focus it)"),
            ("⎋ in filter", "Hide the filter bar"),
            ("⌘R", "Refresh"),
            ("⌘[ / ⌘]", "Previous / next page"),
            ("⌥⌘0", "Row details panel"),
            ("⇧⌘C", "Console log (statements sent to the server)"),
            ("⌃⌘] / ⌃⌘[", "Next / previous connection"),
            ("⌥⌘3", "Relationship diagram"),
            ("⌥⌘4", "Server metrics"),
        ]),
        Group(title: "Data grid", items: [
            ("← → ↑ ↓", "Move between cells"),
            ("Tab / ⇧Tab", "Next / previous cell"),
            ("⌘← ⌘→ ⌘↑ ⌘↓", "First / last column, row"),
            ("↩ or F2", "Edit cell"),
            ("Type any key", "Replace cell value"),
            ("Space", "Quick look at full value"),
            ("⌥⌫", "Set cell to NULL"),
            ("⌫", "Delete selected rows"),
            ("⌘C", "Copy rows (tab-separated)"),
            ("⌥⇧⌘C", "Copy rows with column names"),
            ("⌥⌘C", "Copy cell value"),
            ("⌘A", "Select all rows"),
        ]),
        Group(title: "While editing a cell", items: [
            ("↩", "Save, move down"),
            ("Tab / ⇧Tab", "Save, edit next / previous cell"),
            ("⌥↩", "New line inside the value"),
            ("⎋", "Cancel"),
        ]),
        Group(title: "Changes", items: [
            ("⌘I", "Add row"),
            ("⌘D", "Duplicate row"),
            ("⌘Z / ⇧⌘Z", "Undo / redo uncommitted changes"),
            ("⌘S", "Commit (one transaction)"),
            ("⇧⌘S", "Preview SQL"),
            ("⌥⌘Z", "Discard all changes"),
        ]),
        Group(title: "SQL editor", items: [
            ("⌘↩", "Run selection, or statement at cursor"),
            ("⇧⌘↩", "Run everything"),
            ("⌘/", "Comment / uncomment lines"),
            ("⎋", "Complete table name or keyword"),
            ("⌘F", "Find (when editor is focused)"),
            ("⌘Z / ⇧⌘Z", "Undo / redo (per tab)"),
        ]),
        Group(title: "Redis", items: [
            ("⌘T", "Console"),
            ("⌘F", "Key pattern"),
            ("⌘N", "New key"),
            ("⌘I", "Add element"),
            ("⌘S", "Save string value"),
            ("⌫", "Delete key / elements"),
            ("↑ ↓ in console", "Command history"),
        ]),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 22) {
                ForEach(Self.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title).font(.headline)
                        ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.action).foregroundStyle(.secondary)
                                Spacer(minLength: 12)
                                Text(item.keys)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}
