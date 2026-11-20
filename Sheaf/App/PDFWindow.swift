import AppKit
import SwiftUI

/// A PDF in its own window, to read it beside the main window or another
/// PDF's window (File › Open in New Window). A PDF is in one window at a
/// time: opening it again brings this window forward. Closing the window
/// closes the PDF, saving first. macOS can merge these windows into tabs
/// (Window › Merge All Windows), and reopens them the next time Sheaf opens.
struct PDFWindow: View {
    static let sceneID = "pdf"

    /// The PDF's library ID. Without one there's nothing to show, and the
    /// window closes.
    let id: UUID?

    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var state: ReaderWindow
    @State private var hasAppeared = false
    @State private var isClosing = false

    init(id: UUID?) {
        self.id = id
        _state = State(initialValue: ReaderWindow(kind: .pdf(id ?? UUID())))
    }

    private var document: OpenDocument? {
        id.flatMap(workspace.windowedDocument(id:))
    }

    var body: some View {
        Group {
            if let document {
                ReaderScreen(document: document)
            } else {
                Theme.background
            }
        }
        .readerWindow(state) {
            isClosing = true
            if let id { workspace.ownWindowDidClose(id) }
        }
        .onAppear {
            // Opening PDFs from Finder works even if the main window is closed.
            WindowRouter.shared.attach(openWindow)
            // A window macOS reopened for a PDF that's no longer in the
            // library has nothing to show. Unit tests never open windows.
            guard !SheafApp.isRunningTests, let id, workspace.ownWindowDidAppear(id) else {
                dismissWindow()
                return
            }
            hasAppeared = true
        }
        .onChange(of: document == nil) { _, isGone in
            // Closed with ⌘W, moved to the main window, or removed from the library.
            if isGone && hasAppeared && !isClosing { dismissWindow() }
        }
    }
}
