import SwiftUI

/// The commands for PDFs, shared by the library's context menu and the File
/// menu: open (here or in a new window), Quick Look, show in Finder, share,
/// rename, star, collections and remove from the library. They act on every
/// PDF passed in (the selection).
struct PDFMenuItems: View {
    let entries: [LibraryEntry]
    let collections: [PDFCollection]
    let workspace: Workspace
    /// The File menu's version: every item stays in place (disabled when it
    /// doesn't apply) and has its keyboard shortcut.
    var isMenuBar = false
    /// The window the File menu acts on. The context menu is in the main
    /// window's library.
    var readerWindow: ReaderWindow?

    var body: some View {
        let isEmpty = entries.isEmpty
        // Shortcuts that mean something else in a text field work only
        // while the list has focus, as in Finder.
        let listShortcuts = isMenuBar && workspace.isLibraryListFocused && isLibraryOnScreen
        if isLibraryOnScreen {
            Button(openTitle) { workspace.openPDFs(entries) }
                .keyboardShortcut(listShortcuts ? KeyboardShortcut(.downArrow, modifiers: .command) : nil)
                .disabled(isEmpty)
            // Option-Return and Option-double-click in the list do this too.
            Button(entries.count > 1 ? "Open in New Windows" : "Open in New Window") {
                workspace.openPDFsInNewWindows(entries)
            }
            .keyboardShortcut(listShortcuts ? KeyboardShortcut(.return, modifiers: .option) : nil)
            .disabled(isEmpty)
            Button(workspace.quickLookFile == nil ? "Quick Look" : "Close Quick Look") {
                workspace.toggleQuickLook(entries)
            }
            .keyboardShortcut(isMenuBar ? KeyboardShortcut("y") : nil)
            .disabled(isEmpty && workspace.quickLookFile == nil)
        } else if let readerWindow, let entry = entries.first {
            // The PDF on screen moves into its own window, to read beside
            // another, or back.
            if readerWindow.isMain {
                Button("Open in New Window") { workspace.openInNewWindow(entry) }
            } else {
                Button("Move to Main Window") { workspace.moveToMainWindow(entry.id) }
            }
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
            Button("New Collection\u{2026}") { workspace.requestNewCollection(for: entries) }
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

    /// Whether the window acted on shows the library, rather than a PDF.
    private var isLibraryOnScreen: Bool {
        guard let readerWindow else { return true }
        return readerWindow.isMain && workspace.isShowingLibrary
    }

    private var openTitle: String {
        guard isMenuBar else { return "Open" }
        return entries.count > 1 ? "Open Selected PDFs" : "Open Selected PDF"
    }
}
