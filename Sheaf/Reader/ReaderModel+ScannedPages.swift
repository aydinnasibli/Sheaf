import AppKit
import PDFKit

/// Scanned pages: box highlights and reading their text in the background.
extension ReaderModel {
    /// Call once the page view is on screen (again is fine). Connects box
    /// highlighting to the page view and starts reading scanned pages in
    /// the background, keeping the text in `cacheFolder`.
    func startBackgroundWork(cacheFolder: URL? = RecognizedTextCache.defaultFolder, after delay: Duration = .seconds(1)) {
        pdfView.boxHighlightKind = { [weak self] page, modifiers in
            self?.boxHighlightKind(on: page, modifiers: modifiers)
        }
        pdfView.onBoxDrawn = { [weak self] rect, page, kind in
            guard let self else { return }
            highlightBox(rect, onPage: document.index(for: page), as: kind)
        }
        pdfView.onBoxClick = { [weak self] page in
            self?.boxClicked(on: page)
        }
        scannedPages.onPageRead = { [weak self] page in
            self?.recognizedPageArrived(page)
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

    /// The highlighter for a box dragged on `page`, or nil to select text
    /// as usual: with Option held on any page, and with a highlighter
    /// picked on a page without text. Option-dragging with no highlighter
    /// picked marks a key idea.
    func boxHighlightKind(on page: PDFPage, modifiers: NSEvent.ModifierFlags) -> HighlightKind? {
        guard entry != nil else { return nil }
        let keys = modifiers.intersection(.deviceIndependentFlagsMask)
        if keys.contains(.option), !keys.contains(.command) {
            return activePen ?? .keyIdea
        }
        guard keys.isDisjoint(with: [.command, .control]), let activePen,
              !scannedPages.pageHasText(page, at: document.index(for: page))
        else { return nil }
        return activePen
    }

    /// A click where a box would start: on a scanned page, explain how
    /// highlighting works there.
    private func boxClicked(on page: PDFPage) {
        guard !scannedPages.pageHasText(page, at: document.index(for: page)) else { return }
        showPageNotice(Self.scannedPageNotice)
    }
}
