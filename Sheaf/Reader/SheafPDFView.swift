import PDFKit
import SwiftUI

/// PDFKit's page view with additions for highlighting: it reports when
/// a mouse selection ends and when a page is clicked, handles the 1–4
/// highlighter keys, and lets you drag a box to highlight an area.
final class SheafPDFView: PDFView {
    var onMouseUp: (() -> Void)?
    /// A page was clicked, not dragged on, at this point (in page
    /// coordinates): to open the highlight there.
    var onPageClick: ((PDFPage, CGPoint) -> Void)?
    /// Return true if the key was used.
    var onHighlightKey: ((HighlightKind) -> Bool)?
    /// Asked when the mouse goes down on a page: the highlighter to drag a
    /// box with, or nil to select text as usual. Boxes are for scanned
    /// pages, which have no text to select, and for Option-dragging off
    /// the text (on text, Option-drag selects a block of it, as PDFKit does).
    /// Also given where the mouse is on the page (in page coordinates).
    var boxHighlightKind: ((PDFPage, CGPoint, NSEvent.ModifierFlags) -> HighlightKind?)?
    /// A box was dragged out on a page (in page coordinates).
    var onBoxDrawn: ((CGRect, PDFPage, HighlightKind) -> Void)?
    /// The mouse was clicked, not dragged, where a box would start, at this
    /// point on the page.
    var onBoxClick: ((PDFPage, CGPoint) -> Void)?
    /// Search matches on scanned pages. Set up before any page shows, since
    /// PDFKit asks for page overlays only when it lays out a page.
    let recognizedMatches = RecognizedMatchOverlay()

    override init(frame: NSRect) {
        super.init(frame: frame)
        pageOverlayViewProvider = recognizedMatches
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        pageOverlayViewProvider = recognizedMatches
    }
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
        // A second click (of a double-click that selects a word) isn't a
        // click on a highlight.
        pendingClick?.cancel()
        pendingClick = nil
        if event.clickCount == 1, let (page, kind) = boxStart(for: event) {
            trackBox(from: event, on: page, kind: kind)
            return
        }
        let link = event.clickCount == 1 ? linkAnnotation(at: event) : nil
        if let link, link.destination != nil || link.action is PDFActionGoTo {
            onFollowLink?()
        }
        // Links do their own thing when clicked; Control-click opens the
        // menu, and Shift- or Command-click changes the selection.
        let isPlainClick = event.clickCount == 1 && link == nil
            && event.modifierFlags.isDisjoint(with: [.control, .command, .shift])
        clickStart = isPlainClick ? event.locationInWindow : nil
        super.mouseDown(with: event)
        // PDFView tracks text-selection drags inside mouseDown, so the mouse
        // may already be up by the time it returns.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            onMouseUp?()
            finishClick(at: window?.mouseLocationOutsideOfEventStream)
        }
    }

    /// The link under the mouse, if any.
    private func linkAnnotation(at event: NSEvent) -> PDFAnnotation? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let annotation = page.annotation(at: convert(point, to: page)),
              annotation.type == "Link" || annotation.destination != nil || annotation.action != nil
        else { return nil }
        return annotation
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
        finishClick(at: event.locationInWindow)
    }

    // MARK: Clicks

    /// Where the mouse went down, in window coordinates, while it might be a click.
    private var clickStart: NSPoint?
    private var pendingClick: Task<Void, Never>?

    /// The mouse is up: if it didn't move and selected nothing, it was a
    /// click. It's reported after a moment, unless a second click follows.
    private func finishClick(at location: NSPoint?) {
        guard let start = clickStart else { return }
        clickStart = nil
        guard let location, hypot(location.x - start.x, location.y - start.y) < 4,
              (currentSelection?.string ?? "").isEmpty
        else { return }
        let point = convert(start, from: nil)
        guard let page = page(for: point, nearest: false) else { return }
        let onPage = convert(point, to: page)
        let wait = min(NSEvent.doubleClickInterval, 0.35)
        pendingClick = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.onPageClick?(page, onPage)
        }
    }

    // MARK: Box highlights

    /// The page and highlighter for a box starting at the mouse, if any.
    private func boxStart(for event: NSEvent) -> (PDFPage, HighlightKind)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false),
              let kind = boxHighlightKind?(page, convert(point, to: page), event.modifierFlags)
        else { return nil }
        return (page, kind)
    }

    /// Follows the mouse until it's let go, showing the box as it grows.
    private func trackBox(from event: NSEvent, on page: PDFPage, kind: HighlightKind) {
        let bounds = page.bounds(for: displayBox)
        let start = convert(convert(event.locationInWindow, from: nil), to: page)
        var box = CGRect.null
        let preview = BoxPreview(color: kind.pageColor)
        addSubview(preview)
        NSCursor.crosshair.push()
        defer {
            NSCursor.pop()
            preview.removeFromSuperview()
        }

        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(convert(next.locationInWindow, from: nil), to: page)
            box = CGRect(
                x: min(start.x, point.x), y: min(start.y, point.y),
                width: abs(point.x - start.x), height: abs(point.y - start.y)
            ).intersection(bounds)
            if !box.isNull { preview.frame = convert(box, from: page) }
            if next.type == .leftMouseUp { break }
        }

        // A box smaller than a letter is a click.
        if !box.isNull, box.width >= 4, box.height >= 4 {
            onBoxDrawn?(box, page, kind)
        } else {
            onBoxClick?(page, start)
        }
    }

    /// Set while the crosshair shows that dragging draws a box.
    private var showsBoxCursor = false

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        showsBoxCursor = boxStart(for: event) != nil
        if showsBoxCursor { NSCursor.crosshair.set() }
    }

    /// Pressing or letting go of Option switches the crosshair on and off.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point), let page = page(for: point, nearest: false) else { return }
        let isBox = boxHighlightKind?(page, convert(point, to: page), event.modifierFlags) != nil
        if isBox {
            NSCursor.crosshair.set()
        } else if showsBoxCursor {
            NSCursor.arrow.set()
        }
        showsBoxCursor = isBox
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

/// The box being dragged out, in the highlighter's color.
private final class BoxPreview: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.withAlphaComponent(0.35).cgColor
        layer?.borderColor = (color.blended(withFraction: 0.35, of: .black) ?? color).cgColor
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows the reader's page view inside SwiftUI. The view is owned by
/// `ReaderModel`, so it survives SwiftUI updates.
///
/// A PDF can move to another window (into its own, or back), and the old
/// window may tear down its reader after the new one has shown the page
/// view. So the page view sits in a container of its own here: taking the
/// old container away leaves the page view wherever it is now.
struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> NSView {
        // As big as the page view already is, so it isn't squashed to
        // nothing (and doesn't lose its place) before SwiftUI sizes it.
        let container = NSView(frame: CGRect(origin: .zero, size: pdfView.frame.size))
        pdfView.frame = container.bounds
        pdfView.autoresizingMask = [.width, .height]
        // Takes it out of the container it was in.
        container.addSubview(pdfView)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {}
}
