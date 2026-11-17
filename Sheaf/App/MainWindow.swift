import AppKit
import Observation
import PDFKit
import SwiftUI

/// The app's single window: the library, or the PDF that's open on screen.
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
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { WindowRouter.shared.attach(openWindow) }
    }
}
