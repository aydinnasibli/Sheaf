import AppKit
import Observation
import PDFKit
import SwiftUI

/// The app's main window: the library, or the PDF that's open on screen.
/// PDFs can also have their own windows (see `PDFWindow`).
struct MainWindow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let document = workspace.selectedDocument {
                ReaderScreen(document: document)
                    .id(document.id)
            } else {
                LibraryScreen()
            }
        }
        // Closing the main window keeps its PDFs open, for when it comes back.
        .readerWindow(workspace.mainWindow)
        .onAppear { WindowRouter.shared.attach(openWindow) }
    }
}
