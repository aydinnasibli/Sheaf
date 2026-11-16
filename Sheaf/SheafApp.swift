import SwiftUI

@main
struct SheafApp: App {
    var body: some Scene {
        // Each PDF opens in its own window, like Preview. macOS supplies
        // File > Open, Open Recent, window tabs and Finder's "Open With".
        DocumentGroup(viewing: PDFFile.self) { file in
            ReaderView(data: file.document.data)
        }
        .defaultSize(width: 900, height: 1000)
    }
}
