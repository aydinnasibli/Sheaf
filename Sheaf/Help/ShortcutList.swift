import Foundation

/// Every keyboard shortcut, for the table in the Help window. This is the
/// one place to update: the menus themselves are in SheafCommands.swift, so
/// when a shortcut changes there, change it here too.
enum ShortcutList {
    struct Category: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    struct Shortcut: Identifiable {
        let action: String
        /// The keys as the menus show them, like "⇧⌘F". Some actions have two.
        let keys: [String]
        var id: String { action }

        init(_ action: String, _ keys: String...) {
            self.action = action
            self.keys = keys
        }
    }

    static let categories: [Category] = [
        Category(title: "Highlighting", shortcuts: [
            Shortcut("Highlight the selection, or pick a highlighter", "1 \u{2013} 4", "\u{2318}1 \u{2013} \u{2318}4"),
            Shortcut("Undo", "\u{2318}Z"),
            Shortcut("Redo", "\u{21E7}\u{2318}Z"),
        ]),
        Category(title: "Reading", shortcuts: [
            Shortcut("Previous page", "\u{2325}\u{2318}\u{2191}"),
            Shortcut("Next page", "\u{2325}\u{2318}\u{2193}"),
            Shortcut("Go to a page", "\u{2325}\u{2318}G"),
            Shortcut("Back", "\u{2318}["),
            Shortcut("Forward", "\u{2318}]"),
            Shortcut("Bookmark this page", "\u{2318}D"),
            Shortcut("Focus mode", "\u{21E7}\u{2318}F"),
            Shortcut("Leave focus mode", "Esc", "\u{21E7}\u{2318}F"),
        ]),
        Category(title: "Page size and panels", shortcuts: [
            Shortcut("Fit page", "\u{2318}9"),
            Shortcut("Fit width", "\u{2318}8"),
            Shortcut("Actual size", "\u{2318}0"),
            Shortcut("Zoom in", "\u{2318}+"),
            Shortcut("Zoom out", "\u{2318}\u{2212}"),
            Shortcut("Show or hide pages and contents", "\u{2325}\u{2318}1"),
            Shortcut("Show or hide the Highlights panel", "\u{2325}\u{2318}2"),
        ]),
        Category(title: "Finding", shortcuts: [
            Shortcut("Find in this PDF", "\u{2318}F"),
            Shortcut("Find next", "\u{2318}G"),
            Shortcut("Find previous", "\u{21E7}\u{2318}G"),
            Shortcut("Find the selected text", "\u{2318}E"),
            Shortcut("Search the library", "\u{2318}K"),
        ]),
        Category(title: "PDFs and windows", shortcuts: [
            Shortcut("Open a PDF", "\u{2318}O"),
            Shortcut("Close the PDF", "\u{2318}W"),
            Shortcut("Print", "\u{2318}P"),
            Shortcut("Print without highlights", "\u{2325}\u{2318}P"),
            Shortcut("Library", "\u{21E7}\u{2318}L"),
            Shortcut("Next open PDF", "\u{2303}Tab", "\u{21E7}\u{2318}]"),
            Shortcut("Previous open PDF", "\u{2303}\u{21E7}Tab", "\u{21E7}\u{2318}["),
            Shortcut("Settings", "\u{2318},"),
            Shortcut("Sheaf Help", "\u{2318}?"),
        ]),
    ]
}
