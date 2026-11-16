import SwiftUI

/// Menu bar items. They act on the frontmost tab: the library or a PDF.
struct ReaderCommands: Commands {
    @FocusedValue(ReaderModel.self) private var reader
    @FocusedValue(LibrarySearchFocus.self) private var librarySearch
    @AppStorage("showsThumbnails") private var showsThumbnails = true
    @AppStorage("showsHighlightsPanel") private var showsHighlightsPanel = true

    var body: some Commands {
        // File: Open replaces New, since Sheaf doesn't create PDFs.
        CommandGroup(replacing: .newItem) {
            Button("Open\u{2026}") { WindowRouter.shared.showOpenPanel() }
                .keyboardShortcut("o")
        }

        // Edit > Find. Replaces the text-editing group, which a reader doesn't need.
        CommandGroup(replacing: .textEditing) {
            Button("Find\u{2026}") {
                if let reader {
                    reader.searchFocusRequest += 1
                } else {
                    librarySearch?.request += 1
                }
            }
            .keyboardShortcut("f")
            .disabled(reader == nil && librarySearch == nil)
            Button("Search Library") { librarySearch?.request += 1 }
                .keyboardShortcut("k")
                .disabled(librarySearch == nil)
            Button("Find Next") { reader?.selectNextResult() }
                .keyboardShortcut("g")
                .disabled(reader?.searchResults.isEmpty ?? true)
            Button("Find Previous") { reader?.selectPreviousResult() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(reader?.searchResults.isEmpty ?? true)
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
            Divider()
            Button("Actual Size") { reader?.zoomToActualSize() }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { reader?.zoomToFit() }
                .keyboardShortcut("9")
            Button("Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
            Divider()
            Toggle("Show Page Thumbnails", isOn: $showsThumbnails)
                .keyboardShortcut("1", modifiers: [.command, .option])
            Toggle("Show Highlights Panel", isOn: $showsHighlightsPanel)
                .keyboardShortcut("2", modifiers: [.command, .option])
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
        }
    }
}
