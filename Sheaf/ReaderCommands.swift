import SwiftUI

/// Menu bar items for the frontmost document window.
struct ReaderCommands: Commands {
    @FocusedValue(ReaderModel.self) private var reader
    @FocusedValue(LibrarySearchFocus.self) private var librarySearch

    var body: some Commands {
        // Edit > Find. Replaces the text-editing group, which a reader doesn't need.
        CommandGroup(replacing: .textEditing) {
            Button("Find…") {
                if let reader {
                    reader.searchFocusRequest += 1
                } else {
                    librarySearch?.request += 1
                }
            }
            .keyboardShortcut("f")
            .disabled(reader == nil && librarySearch == nil)
            Button("Find Next") { reader?.selectNextResult() }
                .keyboardShortcut("g")
                .disabled(reader?.searchResults.isEmpty ?? true)
            Button("Find Previous") { reader?.selectPreviousResult() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(reader?.searchResults.isEmpty ?? true)
        }

        // View menu
        CommandGroup(before: .toolbar) {
            Button("Actual Size") { reader?.zoomToActualSize() }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { reader?.zoomToFit() }
                .keyboardShortcut("9")
            Button("Zoom In") { reader?.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out") { reader?.zoomOut() }
                .keyboardShortcut("-")
            Divider()
        }

        CommandMenu("Go") {
            Button("Previous Page") { reader?.goToPreviousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToPreviousPage ?? false))
            Button("Next Page") { reader?.goToNextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!(reader?.canGoToNextPage ?? false))
            Divider()
            Button("Go to Page…") { reader?.isGoToPagePresented = true }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(reader == nil)
        }
    }
}
