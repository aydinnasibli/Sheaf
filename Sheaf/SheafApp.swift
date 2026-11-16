import SwiftUI

@main
struct SheafApp: App {
    var body: some Scene {
        // Each PDF opens in its own window, like Preview. macOS supplies
        // File > Open, Open Recent, window tabs and Finder's "Open With".
        DocumentGroup(viewing: PDFFile.self) { file in
            ReaderView(data: file.document.data, fileURL: file.fileURL)
        }
        .defaultSize(width: 1100, height: 1000)
        .commands { ReaderCommands() }
    }
}
