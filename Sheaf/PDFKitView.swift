import PDFKit
import SwiftUI

/// Shows PDFKit's page view inside SwiftUI.
///
/// SwiftUI has no built-in PDF view, so this wraps PDFKit's AppKit `PDFView`,
/// which provides page rendering, scrolling, zoom and text selection. The view
/// itself is owned by `ReaderModel`, so it survives SwiftUI updates.
struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }

    func updateNSView(_ view: PDFView, context: Context) {}
}

/// PDFKit's page thumbnail strip, linked to the page view so the current
/// page stays highlighted and clicking a thumbnail jumps to that page.
struct ThumbnailView: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.thumbnailSize = CGSize(width: 150, height: 190)
        view.maximumNumberOfColumns = 1
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFThumbnailView, context: Context) {}
}
