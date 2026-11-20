import SwiftUI

/// Menu bar items. They act on what's on screen: the library or a PDF.
struct SheafCommands: Commands {
    let workspace: Workspace

    /// The PDF on screen. Read from the workspace rather than keyboard
    /// focus, so the menus work even while typing in a search field.
    private var reader: ReaderModel? { workspace.selectedDocument?.model }

    /// For File › Add to Collection. Read again when one is made, renamed or deleted.
    private var collections: [PDFCollection] {
        _ = workspace.library.collectionChanges
        return workspace.library.allCollections()
    }

    /// A View menu item for a reader panel: shows or hides it beside the
    /// page, or over the page when the window is too narrow for it.
    private func panelBinding(_ panel: ReaderPanels.Panel) -> Binding<Bool> {
        Binding(
            get: { workspace.readerPanels.isShowing(panel) },
            set: { _ in workspace.readerPanels.toggle(panel) }
        )
    }

    @AppStorage(ReaderModel.darkPagesKey) private var darkPages = false
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Sheaf > Check for Updates…, under About Sheaf as in other Mac apps.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates\u{2026}") { Updater.shared.checkForUpdates() }
                .disabled(!Updater.shared.canCheckForUpdates)
        }

        // File: Open replaces New, since Sheaf doesn't create PDFs.
        CommandGroup(replacing: .newItem) {
            Button("Open\u{2026}") { WindowRouter.shared.showOpenPanel() }
                .keyboardShortcut("o")
        }

        // File > Close: closes the PDF on screen, or the window from the library.
        CommandGroup(replacing: .saveItem) {
            if let document = workspace.selectedDocument {
                Button("Close \u{201C}\(document.title)\u{201D}") { workspace.close(document.id) }
                    .keyboardShortcut("w")
            } else {
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }
        }

        // File > Show in Finder, Share…, Rename…, star, collections and
        // Remove from Library: for the PDF on screen, or the PDFs selected
        // in the library.
        CommandGroup(after: .saveItem) {
            Divider()
            PDFMenuItems(
                entries: workspace.commandTargets,
                collections: collections,
                workspace: workspace,
                isMenuBar: true
            )
        }

        // File > Print, with or without highlights.
        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { reader?.printPDF(includingHighlights: true) }
                .keyboardShortcut("p")
                .disabled(reader == nil)
            Button("Print Without Highlights\u{2026}") { reader?.printPDF(includingHighlights: false) }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(reader == nil)
        }

        // Edit > Find and Edit > Speech. Replaces the text-editing group,
        // whose spelling and text-changing items a reader doesn't need.
        // When a shortcut changes anywhere in this file, update the Help
        // window's table (Help/ShortcutList.swift) too.
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find\u{2026}") {
                    if let reader {
                        reader.searchFocusRequest += 1
                    } else {
                        workspace.librarySearchRequest += 1
                    }
                }
                .keyboardShortcut("f")
                Button("Search Library") {
                    WindowRouter.shared.showLibrary()
                    workspace.librarySearchRequest += 1
                }
                .keyboardShortcut("k")
                Button("Find Next") { reader?.selectNextResult() }
                    .keyboardShortcut("g")
                    .disabled(reader?.searchResults.isEmpty ?? true)
                Button("Find Previous") { reader?.selectPreviousResult() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(reader?.searchResults.isEmpty ?? true)
                // Menus can't tell whether text is selected, so with nothing
                // selected this beeps, as in other Mac apps.
                Button("Use Selection for Find") {
                    if reader?.useSelectionForFind() != true { NSSound.beep() }
                }
                .keyboardShortcut("e")
                .disabled(reader == nil)
            }
            Menu("Speech") {
                Button("Start Speaking") {
                    if let text = reader?.textToSpeak {
                        Speaker.shared.speak(text)
                    } else {
                        NSSound.beep()
                    }
                }
                .disabled(reader == nil)
                Button("Stop Speaking") { Speaker.shared.stop() }
                    .disabled(!Speaker.shared.isSpeaking)
            }
        }

        // View menu
        CommandGroup(before: .toolbar) {
            ForEach(ReaderModel.PageLayout.allCases) { layout in
                Toggle(layout.menuTitle, isOn: Binding(
                    get: { reader?.layout == layout },
                    set: { if $0 { reader?.layout = layout } }
                ))
                .disabled(reader == nil)
            }
            Toggle("Book Spreads (Cover on Its Own)", isOn: Binding(
                get: { reader?.showsBookSpreads ?? false },
                set: { reader?.showsBookSpreads = $0 }
            ))
            .disabled(!(reader?.layout.showsPairs ?? false))
            Divider()
            Button("Actual Size") { reader?.zoomToActualSize() }
                .keyboardShortcut("0")
            Toggle("Fit Page", isOn: Binding(
                get: { reader?.zoomMode == .fitPage },
                set: { _ in reader?.zoomToFit() }
            ))
            .keyboardShortcut("9")
            .disabled(reader == nil)
            Toggle("Fit Width", isOn: Binding(
                get: { reader?.zoomMode == .fitWidth },
                set: { _ in reader?.zoomToWidth() }
            ))
            .keyboardShortcut("8")
            .disabled(reader == nil)
            Button("Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
            Divider()
            Toggle("Dark Pages in Dark Mode", isOn: $darkPages)
            Divider()
            // In a narrow window these show the panel over the page.
            Toggle("Show Pages and Contents", isOn: panelBinding(.pages))
                .keyboardShortcut("1", modifiers: [.command, .option])
            Toggle("Show Highlights Panel", isOn: panelBinding(.highlights))
                .keyboardShortcut("2", modifiers: [.command, .option])
            Toggle("Focus Mode", isOn: Binding(
                get: { workspace.isFocusMode },
                set: { workspace.isFocusMode = $0 }
            ))
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(reader == nil)
            Divider()
        }

        CommandMenu("Highlight") {
            ForEach(HighlightKind.allCases) { kind in
                Button(kind.name) {
                    if reader?.highlightSelection(as: kind) != true {
                        reader?.choosePen(kind)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(kind.rawValue))), modifiers: .command)
                .disabled(reader == nil)
            }
            Divider()
            Button("Stop Highlighting") { reader?.activePen = nil }
                .disabled(reader?.activePen == nil)
        }

        CommandMenu("Go") {
            Button("Library") { WindowRouter.shared.showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Review Highlights") {
                workspace.libraryScope = .review
                WindowRouter.shared.showLibrary()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            // ⇧⌘] and ⇧⌘[ like Safari's tabs; Control-Tab also works (see AppDelegate).
            Button("Next Open PDF") { workspace.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspace.documents.isEmpty)
            Button("Previous Open PDF") { workspace.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspace.documents.isEmpty)
            Divider()
            Button("Previous Page") { reader?.goToPreviousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToPreviousPage ?? false))
            Button("Next Page") { reader?.goToNextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToNextPage ?? false))
            Divider()
            Button("Go to Page\u{2026}") { reader?.isGoToPagePresented = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(reader == nil)
            Divider()
            // Back to where you were before following a link or jumping.
            Button("Back") { reader?.goBack() }
                .keyboardShortcut("[")
                .disabled(!(reader?.canGoBack ?? false))
            Button("Forward") { reader?.goForward() }
                .keyboardShortcut("]")
                .disabled(!(reader?.canGoForward ?? false))
            Divider()
            Toggle("Bookmark This Page", isOn: Binding(
                get: { reader?.isCurrentPageBookmarked ?? false },
                set: { _ in reader?.toggleBookmark() }
            ))
            .keyboardShortcut("d")
            .disabled(reader?.entry == nil)
        }

        // Help > Sheaf Help opens Sheaf's own help window.
        CommandGroup(replacing: .help) {
            Button("Sheaf Help") { openWindow(id: HelpView.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
