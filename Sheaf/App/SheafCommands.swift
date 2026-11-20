import AppKit
import SwiftUI

/// Menu bar items. They act on what's on screen in the window in front:
/// the library or a PDF in the main window, or a PDF in its own window.
/// With another kind of window in front (Help, Settings), or none, the
/// items for a PDF or the library are disabled, and File › Close closes
/// whichever window is in front.
///
/// When a shortcut changes anywhere in this file, update the Help window's
/// table (Help/ShortcutList.swift) too.
struct SheafCommands: Commands {
    let workspace: Workspace

    /// The reading window the menus act on: the key window, or the one a
    /// sheet or popover in front belongs to. It's the window, not the view
    /// with keyboard focus, so the menus work even while typing in a search
    /// field. `nil` while Help, Settings, an Open or Save panel or no window
    /// is in front.
    private var window: ReaderWindow? { FrontReaderWindow.shared.window }

    /// The PDF on screen in that window.
    private var document: OpenDocument? { window.flatMap(workspace.document(in:)) }
    private var reader: ReaderModel? { document?.model }
    /// Whether the main window is in front showing the library.
    private var isLibraryInFront: Bool { window?.isMain == true && workspace.isShowingLibrary }

    /// For File › Add to Collection. Read again when one is made, renamed or deleted.
    private var collections: [PDFCollection] {
        _ = workspace.library.collectionChanges
        return workspace.library.allCollections()
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

        // File > Close: closes the PDF on screen; from the library, or with
        // Help or Settings in front, the window. A PDF's own window closes
        // with its PDF.
        CommandGroup(replacing: .saveItem) {
            if let document {
                Button("Close \u{201C}\(document.title)\u{201D}") { workspace.close(document.id) }
                    .keyboardShortcut("w")
            } else {
                Button(window?.isMain == true ? "Close Window" : "Close") {
                    if let key = NSApp.keyWindow { key.performClose(nil) } else { NSSound.beep() }
                }
                .keyboardShortcut("w")
            }
        }

        // File > Open in New Window, Show in Finder, Share…, Rename…, star,
        // collections and Remove from Library: for the PDF on screen, or
        // the PDFs selected in the library.
        CommandGroup(after: .saveItem) {
            Divider()
            PDFMenuItems(
                entries: window.map(workspace.commandTargets(in:)) ?? [],
                collections: collections,
                workspace: workspace,
                isMenuBar: true,
                readerWindow: window
            )
        }

        // File > Export as Markdown…: the PDF on screen's summary, highlights
        // and notes, or what the library's Highlights or Notes page shows.
        CommandGroup(replacing: .importExport) {
            Button("Export as Markdown\u{2026}") {
                if let reader {
                    reader.exportMarkdown()
                } else if isLibraryInFront {
                    NotificationCenter.default.post(name: .sheafExportShownHighlights, object: nil)
                }
            }
            .disabled(reader == nil && !(isLibraryInFront && workspace.libraryScope.showsHighlights))
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

        // Edit > Copy as Quote: “the text” (Title, p. 245), for an essay.
        CommandGroup(after: .pasteboard) {
            // Menus can't tell whether text is selected, so with nothing to
            // quote this beeps, like Use Selection for Find.
            Button("Copy as Quote") {
                if reader?.copyQuote() != true { NSSound.beep() }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(reader == nil)
        }

        // Edit > Find, Spelling and Grammar, Substitutions, Transformations
        // and Speech, in the standard order. Find and Speech are Sheaf's own
        // (they search and read the PDF); the others are the standard ones,
        // for writing notes, answers and summaries.
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find\u{2026}") {
                    if let reader {
                        reader.searchFocusRequest += 1
                    } else if isLibraryInFront {
                        workspace.librarySearchRequest += 1
                    }
                }
                .keyboardShortcut("f")
                .disabled(reader == nil && !isLibraryInFront)
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
            TextEditingMenus()
            Menu("Speech") {
                Button("Start Speaking") {
                    if let text = reader?.textToSpeak {
                        Speaker.shared.speak(text)
                    } else if !NSApp.sendAction(#selector(NSTextView.startSpeaking(_:)), to: nil, from: nil) {
                        // Without a PDF, the text field being typed in reads its text.
                        NSSound.beep()
                    }
                }
                Button("Stop Speaking") {
                    Speaker.shared.stop()
                    NSApp.sendAction(#selector(NSTextView.stopSpeaking(_:)), to: nil, from: nil)
                }
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
                .disabled(reader == nil)
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
            // ⌘= zooms in too, without Shift (see AppDelegate).
            Button("Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(reader == nil)
            Button("Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(reader == nil)
            Divider()
            Toggle("Dark Pages in Dark Mode", isOn: $darkPages)
            Divider()
            // Show or Hide, as in other Mac apps. In a narrow window these
            // show the panel over the page. Focus mode hides both.
            panelButton(.pages, title: "Pages and Contents")
                .keyboardShortcut("1", modifiers: [.command, .option])
            panelButton(.highlights, title: "Highlights Panel")
                .keyboardShortcut("2", modifiers: [.command, .option])
            // Full screen for this window only.
            Toggle("Focus Mode", isOn: window.map { Bindable($0).isFocusMode } ?? .constant(false))
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(reader == nil)
            Divider()
        }

        // Go comes right after View, as in Preview; the menus are added in
        // the order they're declared.
        CommandMenu("Go") {
            Button("Library") { WindowRouter.shared.showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Review Highlights") {
                workspace.libraryScope = .review
                WindowRouter.shared.showLibrary()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            // ⇧⌘] and ⇧⌘[ like Safari's tabs; Control-Tab also works (see
            // AppDelegate). They switch the main window's PDFs, so only
            // while the main window is in front.
            Button("Next Open PDF") { workspace.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(workspace.documents.isEmpty || window?.isMain != true)
            Button("Previous Open PDF") { workspace.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(workspace.documents.isEmpty || window?.isMain != true)
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

        CommandMenu("Highlight") {
            ForEach(HighlightKind.allCases) { kind in
                Button(kind.menuTitle) {
                    if reader?.highlightSelection(as: kind) != true {
                        reader?.choosePen(kind)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(kind.rawValue))), modifiers: .command)
                .disabled(reader == nil)
            }
            Divider()
            // ⌘. stops, as it does elsewhere on the Mac. Esc on the page does it too.
            Button("Stop Highlighting") { reader?.activePen = nil }
                .keyboardShortcut(".")
                .disabled(reader?.activePen == nil)
            Divider()
            // The highlight just made (or clicked): its note on its card, or
            // in a popover at the highlight when the panel is hidden.
            Button(reader?.targetHighlight?.note.isEmpty == false ? "Edit Note on Highlight" : "Add Note to Highlight") {
                if reader?.editNoteOfHighlight() != true { NSSound.beep() }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(reader?.highlights.isEmpty ?? true)
            Button(reader.map { $0.hasPageNote(onPage: $0.currentPageIndex) } == true ? "Edit Page Note" : "Add Page Note") {
                if let reader { reader.editPageNote(onPage: reader.currentPageIndex) }
            }
            .keyboardShortcut("n", modifiers: [.command, .control])
            .disabled(reader?.entry == nil)
        }

        // Help > Sheaf Help opens Sheaf's own help window.
        CommandGroup(replacing: .help) {
            Button("Sheaf Help") { openWindow(id: HelpView.windowID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    /// View › Show or Hide a reader panel: beside the page, or over the page
    /// when the window is too narrow for it.
    private func panelButton(_ panel: ReaderPanels.Panel, title: String) -> some View {
        let isShowing = reader != nil && (window?.panels.isShowing(panel) ?? false)
        return Button(isShowing ? "Hide \(title)" : "Show \(title)") { window?.panels.toggle(panel) }
            .disabled(reader == nil || window?.isFocusMode == true)
    }
}

extension HighlightKind {
    /// The highlighter's name in title case, for menus: "Key Idea".
    var menuTitle: String { name.capitalized }
}

/// Edit › Spelling and Grammar, Substitutions and Transformations, as in
/// other Mac apps, for writing notes, answers and summaries. Like AppKit's
/// own items they act on the text being typed, through the responder chain;
/// with no text field in use they beep. They stay enabled, since the menus
/// can't follow which field has the keyboard.
private struct TextEditingMenus: View {
    var body: some View {
        // Looked at again each time the menu bar opens, so the check marks
        // show the settings of the field being typed in.
        let _ = FrontReaderWindow.shared.menuOpenings
        let text = NSApp.keyWindow?.firstResponder as? NSTextView
        Menu("Spelling and Grammar") {
            command("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)))
                .keyboardShortcut(":", modifiers: .command)
            command("Check Document Now", #selector(NSText.checkSpelling(_:)))
                .keyboardShortcut(";", modifiers: .command)
            Divider()
            setting("Check Spelling While Typing", text?.isContinuousSpellCheckingEnabled, #selector(NSTextView.toggleContinuousSpellChecking(_:)))
            setting("Check Grammar With Spelling", text?.isGrammarCheckingEnabled, #selector(NSTextView.toggleGrammarChecking(_:)))
            setting("Correct Spelling Automatically", text?.isAutomaticSpellingCorrectionEnabled, #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)))
        }
        Menu("Substitutions") {
            command("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:)))
            Divider()
            setting("Smart Copy/Paste", text?.smartInsertDeleteEnabled, #selector(NSTextView.toggleSmartInsertDelete(_:)))
            setting("Smart Quotes", text?.isAutomaticQuoteSubstitutionEnabled, #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)))
            setting("Smart Dashes", text?.isAutomaticDashSubstitutionEnabled, #selector(NSTextView.toggleAutomaticDashSubstitution(_:)))
            setting("Smart Links", text?.isAutomaticLinkDetectionEnabled, #selector(NSTextView.toggleAutomaticLinkDetection(_:)))
            setting("Data Detectors", text?.isAutomaticDataDetectionEnabled, #selector(NSTextView.toggleAutomaticDataDetection(_:)))
            setting("Text Replacement", text?.isAutomaticTextReplacementEnabled, #selector(NSTextView.toggleAutomaticTextReplacement(_:)))
        }
        Menu("Transformations") {
            command("Make Upper Case", #selector(NSResponder.uppercaseWord(_:)))
            command("Make Lower Case", #selector(NSResponder.lowercaseWord(_:)))
            command("Capitalize", #selector(NSResponder.capitalizeWord(_:)))
        }
    }

    private func command(_ title: String, _ action: Selector) -> some View {
        Button(title) { Self.send(action) }
    }

    private func setting(_ title: String, _ isOn: Bool?, _ action: Selector) -> some View {
        Toggle(title, isOn: Binding(get: { isOn ?? false }, set: { _ in Self.send(action) }))
    }

    private static func send(_ action: Selector) {
        if !NSApp.sendAction(action, to: nil, from: nil) { NSSound.beep() }
    }
}
