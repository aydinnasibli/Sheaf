import SwiftUI

/// The commands for PDFs, shared by the library's context menu and the File
/// menu: open, Quick Look, show in Finder, share, rename, star, collections
/// and remove from the library. They act on every PDF passed in (the selection).
struct PDFMenuItems: View {
    let entries: [LibraryEntry]
    let collections: [PDFCollection]
    let workspace: Workspace
    /// The File menu's version: every item stays in place (disabled when it
    /// doesn't apply) and has its keyboard shortcut.
    var isMenuBar = false

    var body: some View {
        let isEmpty = entries.isEmpty
        // Shortcuts that mean something else in a text field work only
        // while the list has focus, as in Finder.
        let listShortcuts = isMenuBar && workspace.isLibraryListFocused && workspace.isShowingLibrary
        if !isMenuBar || workspace.isShowingLibrary {
            Button(openTitle) { workspace.openPDFs(entries) }
                .keyboardShortcut(listShortcuts ? KeyboardShortcut(.downArrow, modifiers: .command) : nil)
                .disabled(isEmpty)
            Button(workspace.quickLookFile == nil ? "Quick Look" : "Close Quick Look") {
                workspace.toggleQuickLook(entries)
            }
            .keyboardShortcut(isMenuBar ? KeyboardShortcut("y") : nil)
            .disabled(isEmpty && workspace.quickLookFile == nil)
        }
        Button("Show in Finder") { workspace.showInFinder(entries) }
            .keyboardShortcut(isMenuBar ? KeyboardShortcut("r", modifiers: [.command, .option]) : nil)
            .disabled(isEmpty)
        Button("Share\u{2026}") { workspace.share(entries) }
            .disabled(isEmpty)
        if isMenuBar || entries.count == 1 {
            Button("Rename\u{2026}") {
                if let entry = entries.first { workspace.requestRename(entry) }
            }
            .disabled(entries.count != 1)
        }

        Divider()

        let allStarred = !isEmpty && entries.allSatisfy(\.isStarred)
        Button(allStarred ? "Unstar" : "Star") { workspace.setStarred(!allStarred, for: entries) }
            .disabled(isEmpty)
        Menu("Add to Collection") {
            ForEach(collections) { collection in
                Button(collection.name) { workspace.move(entries, to: collection) }
            }
            if !collections.isEmpty { Divider() }
            Button("New Collection") { workspace.moveToNewCollection(entries) }
        }
        .disabled(isEmpty)
        let inCollection = entries.contains { $0.collection != nil }
        if isMenuBar || inCollection {
            Button("Remove from Collection") { workspace.move(entries, to: nil) }
                .disabled(!inCollection)
        }

        Divider()

        Button("Remove from Library\u{2026}", role: .destructive) { workspace.requestRemoval(of: entries) }
            .keyboardShortcut(listShortcuts ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .disabled(isEmpty)
    }

    private var openTitle: String {
        guard isMenuBar else { return "Open" }
        return entries.count > 1 ? "Open Selected PDFs" : "Open Selected PDF"
    }
}
