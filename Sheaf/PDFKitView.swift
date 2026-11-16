import PDFKit
import SwiftUI

/// Shows PDFKit's page view inside SwiftUI.
///
/// SwiftUI has no built-in PDF view, so this wraps PDFKit's AppKit `PDFView`,
/// which provides page rendering, scrolling, zoom and text selection.
struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.autoScales = true
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
