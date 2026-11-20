import AppKit
import Foundation
import Testing
@testable import Sheaf

/// The menu bar the app builds, as macOS has it. The tests run with no
/// window open, which is also how the menus are with Help or Settings in
/// front: no reading window, so nothing should act on a hidden PDF.
@MainActor
struct MenuBarTests {
    /// The app's menu bar, once SwiftUI has built it.
    private func mainMenu() async throws -> NSMenu {
        for _ in 0..<40 {
            if let menu = NSApp.mainMenu, menu.item(withTitle: "Highlight") != nil { return menu }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(NSApp.mainMenu)
    }

    private func submenu(_ title: String, of menu: NSMenu) throws -> NSMenu {
        let menu = try #require(menu.item(withTitle: title)?.submenu, "No \(title) menu")
        menu.update()
        return menu
    }

    @Test func goComesRightAfterView() async throws {
        let titles = try await mainMenu().items.map(\.title)
        let view = try #require(titles.firstIndex(of: "View"))
        #expect(titles[view + 1] == "Go")
        #expect(titles[view + 2] == "Highlight")
    }

    @Test func theEditMenuHasTheStandardTextItems() async throws {
        let edit = try submenu("Edit", of: try await mainMenu())
        let submenus = edit.items.filter { $0.submenu != nil }.map(\.title)
        let expected = ["Find", "Spelling and Grammar", "Substitutions", "Transformations", "Speech"]
        #expect(Array(submenus.drop { $0 != "Find" }.prefix(expected.count)) == expected)
        let spelling = try submenu("Spelling and Grammar", of: edit)
        #expect(spelling.items.contains { $0.title == "Check Spelling While Typing" })
        let substitutions = try submenu("Substitutions", of: edit)
        #expect(substitutions.items.contains { $0.title == "Smart Quotes" })
        #expect(edit.item(withTitle: "Copy as Quote") != nil)
        let find = try submenu("Find", of: edit)
        #expect(find.item(withTitle: "Use Selection for Find") != nil)
    }

    @Test func withNoReadingWindowTheMenusLeaveThePDFsAlone() async throws {
        let menu = try await mainMenu()
        let file = try submenu("File", of: menu)
        let close = try #require(file.items.first { $0.keyEquivalent == "w" })
        #expect(close.title == "Close")

        let view = try submenu("View", of: menu)
        for title in ["Actual Size", "Zoom In", "Zoom Out", "Fit Page", "Show Pages and Contents", "Show Highlights Panel", "Focus Mode"] {
            let item = try #require(view.item(withTitle: title), "No \(title) in View")
            #expect(!item.isEnabled, "\(title) is enabled")
        }

        let highlight = try submenu("Highlight", of: menu)
        #expect(highlight.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
        #expect(highlight.item(withTitle: "Key Idea") != nil)
        #expect(highlight.item(withTitle: "Stop Highlighting")?.keyEquivalent == ".")

        let go = try submenu("Go", of: menu)
        #expect(go.item(withTitle: "Bookmark This Page")?.isEnabled == false)
        #expect(go.item(withTitle: "Library")?.isEnabled == true)
    }

    /// Every shortcut in Sheaf's menus is in the Help window's table.
    @Test func theHelpTableHasEveryMenuShortcut() async throws {
        let listed = Set(ShortcutList.categories.flatMap(\.shortcuts).flatMap(\.keys).flatMap(Self.expanded))
        var missing: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items where !item.isHidden && !Self.systemActions.contains(item.action.map(NSStringFromSelector) ?? "") {
                if let submenu = item.submenu { walk(submenu) }
                guard !item.keyEquivalent.isEmpty, let keys = Self.keys(of: item), !Self.system.contains(keys) else { continue }
                if !listed.contains(keys) { missing.append("\(item.title) \(keys)") }
            }
        }
        walk(try await mainMenu())
        #expect(missing.isEmpty, "Not in ShortcutList: \(missing.joined(separator: ", "))")
    }

    /// macOS's own shortcuts, which the table doesn't need to repeat.
    private static let system: Set<String> = [
        "\u{2318}H", "\u{2325}\u{2318}H", "\u{2318}Q", "\u{2318}M",
        "\u{2318}X", "\u{2318}C", "\u{2318}V", "\u{2303}\u{2318}F",
        "\u{2303}\u{2318}Space", "\u{2325}\u{2318}T",
    ]

    /// Items macOS adds to every app's Edit menu.
    private static let systemActions: Set<String> = ["startDictation:", "orderFrontCharacterPalette:"]

    /// "⌘1 – ⌘4" stands for ⌘1, ⌘2, ⌘3 and ⌘4.
    private static func expanded(_ keys: String) -> [String] {
        let parts = keys.components(separatedBy: " \u{2013} ")
        guard parts.count == 2, let last = parts[1].last?.wholeNumberValue, let first = parts[0].last?.wholeNumberValue else {
            return [keys]
        }
        let prefix = String(parts[0].dropLast())
        return (first...last).map { "\(prefix)\($0)" }
    }

    /// The keys as the menu shows them, like "⇧⌘G".
    private static func keys(of item: NSMenuItem) -> String? {
        let mask = item.keyEquivalentModifierMask
        var keys = ""
        if mask.contains(.control) { keys += "\u{2303}" }
        if mask.contains(.option) { keys += "\u{2325}" }
        if mask.contains(.shift) { keys += "\u{21E7}" }
        if mask.contains(.command) { keys += "\u{2318}" }
        let key: String
        switch item.keyEquivalent {
        case "\u{F700}": key = "\u{2191}"
        case "\u{F701}": key = "\u{2193}"
        case "\u{8}", "\u{7F}": key = "\u{232B}"
        case "\r": key = "Return"
        case " ": key = "Space"
        case "-": key = "\u{2212}"
        default: key = item.keyEquivalent.uppercased()
        }
        return keys + key
    }
}
