import AppKit
import PDFKit
import QuartzCore

/// Marks search matches on scanned pages. PDFKit can only highlight text
/// it knows about, and these pages have none, so Sheaf lays a see-through
/// view over each page and marks the matches there.
///
/// PDFKit asks for these views only when it lays out a page, so the page
/// view sets this up before it shows any page. Pages without matches get
/// an empty view, which costs next to nothing.
final class RecognizedMatchOverlay: NSObject, PDFPageOverlayViewProvider {
    /// The matches on each page, in page coordinates.
    private(set) var marks: [Int: [CGRect]] = [:]
    /// The match picked in the results.
    private(set) var selected: (page: Int, rect: CGRect)?
    private var views: [Int: MarksView] = [:]

    func show(_ marks: [Int: [CGRect]], selected: (page: Int, rect: CGRect)?) {
        // Nothing to change: skip touching every page's view.
        if marks.isEmpty, self.marks.isEmpty, selected == nil, self.selected == nil { return }
        self.marks = marks
        self.selected = selected
        for view in views.values { view.update() }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        let overlay = MarksView(overlay: self, page: page, index: index, displayBox: view.displayBox)
        views[index] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        if let index = views.first(where: { $0.value === overlayView })?.key {
            views[index] = nil
        }
    }

    /// The view over one page, as big as the page. It never takes clicks, so
    /// selecting text and following links work as usual.
    final class MarksView: NSView {
        private weak var overlay: RecognizedMatchOverlay?
        private weak var page: PDFPage?
        private let index: Int
        private let displayBox: PDFDisplayBox

        init(overlay: RecognizedMatchOverlay, page: PDFPage, index: Int, displayBox: PDFDisplayBox) {
            self.overlay = overlay
            self.page = page
            self.index = index
            self.displayBox = displayBox
            super.init(frame: .zero)
            // Marks are layers, not drawing, so an empty page needs no image
            // and marks stay sharp at any zoom.
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            update()
        }

        func update() {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }

            guard let overlay, let page else { return }
            let rects = overlay.marks[index] ?? []
            let selected = overlay.selected.flatMap { $0.page == index ? $0.rect : nil }
            guard !rects.isEmpty || selected != nil else { return }

            // The view covers the page as it's shown (turned, if the page is
            // rotated), so page coordinates map straight onto it.
            let turn = page.transform(for: displayBox)
            let shown = page.bounds(for: displayBox).applying(turn)
            guard shown.width > 0, shown.height > 0, bounds.width > 0, bounds.height > 0 else { return }
            let toView = turn
                .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
                .concatenating(CGAffineTransform(scaleX: bounds.width / shown.width, y: bounds.height / shown.height))

            func mark(_ rect: CGRect, opacity: CGFloat, outlined: Bool) {
                let mark = CALayer()
                mark.frame = rect.applying(toView).insetBy(dx: -1.5, dy: -1)
                // See-through, since the view lies on top of the scanned text.
                mark.backgroundColor = NSColor.findHighlightColor.withAlphaComponent(opacity).cgColor
                mark.cornerRadius = 2
                if outlined {
                    mark.borderColor = (NSColor.findHighlightColor.blended(withFraction: 0.5, of: .black) ?? .black).cgColor
                    mark.borderWidth = 1.5
                }
                layer.addSublayer(mark)
            }
            for rect in rects where rect != selected {
                mark(rect, opacity: 0.4, outlined: false)
            }
            if let selected {
                mark(selected, opacity: 0.55, outlined: true)
            }
        }
    }
}
