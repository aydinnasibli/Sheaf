import AppKit
import PDFKit

/// Scanned pages: box highlights and reading their text in the background.
extension ReaderModel {
    /// Call once the page view is on screen (again is fine). Connects box
    /// highlighting to the page view and starts reading scanned pages in
    /// the background, keeping the text in `cacheFolder`.
    func startBackgroundWork(cacheFolder: URL? = RecognizedTextCache.defaultFolder, after delay: Duration = .seconds(1)) {
        pdfView.boxHighlightKind = { [weak self] page, point, modifiers in
            self?.boxHighlightKind(on: page, at: point, modifiers: modifiers)
        }
        pdfView.onBoxDrawn = { [weak self] rect, page, kind in
            guard let self else { return }
            highlightBox(rect, onPage: document.index(for: page), as: kind)
        }
        pdfView.onBoxClick = { [weak self] page, point in
            self?.boxClicked(on: page, at: point)
        }
        scannedPages.onPageRead = { [weak self] page in
            self?.recognizedPageArrived(page)
        }
        // The library's search finds the words read off scanned pages too.
        let entryID = entry?.id
        scannedPages.onFinished = {
            if let entryID { TextIndexer.shared.index(entryID: entryID) }
        }
        scannedPages.startReading(
            using: renderer, pageCount: pageCount, fileURL: fileURL, libraryID: entry?.id,
            cacheFolder: cacheFolder, after: delay
        )
    }

    /// Whether the page has text to select (scanned pages don't).
    func pageHasText(_ index: Int) -> Bool {
        guard let page = document.page(at: index) else { return false }
        return scannedPages.pageHasText(page, at: index)
    }

    /// The highlighter for a box dragged on `page` from `point` (in page
    /// coordinates), or nil to select text as usual: with Option held, off
    /// the text or anywhere on a page without text, and with a highlighter
    /// picked on a page without text. Option-dragging with no highlighter
    /// picked marks a key idea. Option-dragging on text selects a block of
    /// it, as in Preview.
    func boxHighlightKind(on page: PDFPage, at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> HighlightKind? {
        guard entry != nil else { return nil }
        let keys = modifiers.intersection(.deviceIndependentFlagsMask)
        let hasText = scannedPages.pageHasText(page, at: document.index(for: page))
        if keys.contains(.option), !keys.contains(.command) {
            guard !hasText || !Self.isOnText(point, of: page) else { return nil }
            return activePen ?? .keyIdea
        }
        guard keys.isDisjoint(with: [.command, .control]), let activePen, !hasText else { return nil }
        return activePen
    }

    /// Whether `point` (in page coordinates) is on a line of text, or just
    /// beside one: between two lines counts as on the text.
    static func isOnText(_ point: CGPoint, of page: PDFPage) -> Bool {
        let around = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
        let text = page.selection(for: around)?.string ?? ""
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A click where a box would start: on a highlight, opens it, as a
    /// click does anywhere; elsewhere on a scanned page, explains how
    /// highlighting works there.
    private func boxClicked(on page: PDFPage, at point: CGPoint) {
        if highlight(at: point, onPage: document.index(for: page)) != nil {
            pageClicked(page, at: point)
            return
        }
        guard !scannedPages.pageHasText(page, at: document.index(for: page)) else { return }
        showPageNotice(Self.scannedPageNotice)
    }
}
