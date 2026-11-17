import PDFKit
import SwiftUI

/// PDFKit's page view with two additions for highlighting: it reports when
/// a mouse selection ends, and handles the 1–4 highlighter keys.
final class SheafPDFView: PDFView {
    var onMouseUp: (() -> Void)?
    /// Return true if the key was used.
    var onHighlightKey: ((HighlightKind) -> Bool)?
    /// Esc in the page. Return true if it was used (it ends focus mode).
    var onEscape: (() -> Bool)?
    /// Light or Dark Mode changed (dark pages follow it).
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// A link to another place in the PDF is about to be followed.
    var onFollowLink: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, isInternalLink(at: event) {
            onFollowLink?()
        }
        super.mouseDown(with: event)
        // PDFView tracks text-selection drags inside mouseDown, so the mouse
        // may already be up by the time it returns.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            onMouseUp?()
        }
    }

    /// Whether the click is on a link to a page in this PDF (not a web link).
    private func isInternalLink(at event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page))
        else { return false }
        return annotation.destination != nil || annotation.action is PDFActionGoTo
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if event.keyCode == 53, modifiers.isEmpty, onEscape?() == true {
            return
        }
        if modifiers.isEmpty,
           let characters = event.charactersIgnoringModifiers,
           let number = Int(characters),
           let kind = HighlightKind(rawValue: number),
           onHighlightKey?(kind) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Shows the reader's page view inside SwiftUI. The view is owned by
/// `ReaderModel`, so it survives SwiftUI updates.
struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFView { pdfView }

    func updateNSView(_ view: PDFView, context: Context) {}
}
