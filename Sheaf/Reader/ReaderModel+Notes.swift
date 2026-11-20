import AppKit
import PDFKit

/// Notes while reading: acting on a highlight right on the page, notes on
/// whole pages, the summary, and quoting what she highlighted.
extension ReaderModel {
    // MARK: Selecting a highlight

    var selectedHighlight: HighlightRecord? {
        selectedHighlightID.flatMap(highlight(id:))
    }

    /// The highlight made last.
    var latestHighlight: HighlightRecord? {
        highlights.max { $0.createdAt < $1.createdAt }
    }

    /// What the note shortcut and Copy as Quote act on: the highlight
    /// clicked or just made, else the one made last.
    var targetHighlight: HighlightRecord? {
        selectedHighlight ?? latestHighlight
    }

    /// Selects a highlight, so its card in the panel is outlined and
    /// scrolled into view. A color filter that would hide it lets its
    /// color through.
    func select(_ record: HighlightRecord) {
        selectedHighlightID = record.id
        if !panelFilter.isEmpty, !panelFilter.contains(record.kind) {
            panelFilter.insert(record.kind)
        }
    }

    /// The highlight at a point on a page (in page coordinates). Where
    /// highlights overlap, the newest is on top.
    func highlight(at point: CGPoint, onPage index: Int) -> HighlightRecord? {
        highlights
            .filter { $0.pageIndex == index && $0.rects.contains { $0.insetBy(dx: -2, dy: -2).contains(point) } }
            .max { $0.createdAt < $1.createdAt }
    }

    /// A click on a page that wasn't a drag. On a highlight it selects it
    /// and opens its popover; anywhere else it clears the selection.
    func pageClicked(_ page: PDFPage, at point: CGPoint) {
        guard let record = highlight(at: point, onPage: document.index(for: page)) else {
            selectedHighlightID = nil
            return
        }
        select(record)
        showPopover(for: record, near: point)
    }

    // MARK: Notes on highlights

    /// The note shortcut: opens the note of the highlight just made (or the
    /// one clicked), on its card in the panel or, with the panel hidden, in
    /// a popover at the highlight. Returns false if there are no highlights.
    @discardableResult
    func editNoteOfHighlight() -> Bool {
        guard let record = targetHighlight else { return false }
        select(record)
        if isHighlightsPanelVisible {
            pendingNoteEditID = record.id
        } else if let page = document.page(at: record.pageIndex), let line = record.rects.first,
                  visibleRect(of: line, on: page) == nil {
            // Off screen: go there first, then point at it.
            go(to: record)
            Task { [weak self] in self?.showPopover(for: record) }
        } else {
            showPopover(for: record)
        }
        return true
    }

    /// The popover at a highlight: its note, the four colors, Copy, Copy as
    /// Quote and Delete. A note typed in it is saved when it closes, unless
    /// she pressed Esc.
    func showPopover(for record: HighlightRecord, near point: CGPoint? = nil) {
        guard let page = document.page(at: record.pageIndex) else { return }
        let lines = record.rects
        let clicked = point.flatMap { point in lines.first { $0.insetBy(dx: -2, dy: -2).contains(point) } }
        guard let line = clicked ?? lines.first else { return }
        let id = record.id
        let draft = NoteDraft(text: record.note)
        let content = HighlightPopoverView(model: self, id: id, draft: draft) { [weak self] in
            self?.popover.close()
        }
        popover.show(content, in: pdfView, edge: pdfView.isFlipped ? .minY : .maxY) { [weak self] in
            self?.visibleRect(of: line, on: page)
        } onClose: { [weak self] in
            guard let self, !draft.isCancelled, let record = highlight(id: id) else { return }
            setNote(draft.text, for: record)
            // An answer typed and not yet saved with Return is kept too;
            // an empty one leaves the question as it was.
            if let answer = draft.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setAnswer(answer, isAnswered: true, for: record)
            }
        }
    }

    /// Where a rectangle on a page is in the page view, if it's on screen.
    func visibleRect(of rect: CGRect, on page: PDFPage) -> CGRect? {
        guard pdfView.visiblePages.contains(page) else { return nil }
        let shown = pdfView.convert(rect, from: page).intersection(pdfView.bounds)
        return shown.isNull || shown.isEmpty ? nil : shown
    }

    // MARK: Page notes

    func pageNote(onPage index: Int) -> PageNote? {
        pageNotes.first { $0.pageIndex == index }
    }

    func hasPageNote(onPage index: Int) -> Bool {
        pageNotes.contains { $0.pageIndex == index }
    }

    /// Add Page Note: opens the page's note (an empty one if it has none)
    /// on the panel or, with the panel hidden, in a popover over the page.
    func editPageNote(onPage index: Int) {
        guard entry != nil, let page = document.page(at: index) else { return }
        if isHighlightsPanelVisible {
            if pageNote(onPage: index) == nil { pageNoteDraftPage = index }
            pendingPageNoteEdit = index
        } else if !pdfView.visiblePages.contains(page) {
            goToPage(number: index + 1)
            Task { [weak self] in self?.showPageNotePopover(onPage: index) }
        } else {
            showPageNotePopover(onPage: index)
        }
    }

    /// The page note in a popover near the top of the page.
    func showPageNotePopover(onPage index: Int) {
        guard let page = document.page(at: index) else { return }
        let draft = NoteDraft(text: pageNote(onPage: index)?.text ?? "")
        let content = PageNotePopoverView(model: self, pageIndex: index, draft: draft) { [weak self] in
            self?.popover.close()
        }
        // Points down at the top of the page, so the popover covers the page's top rather than the toolbar.
        popover.show(content, in: pdfView, edge: pdfView.isFlipped ? .maxY : .minY) { [weak self] in
            self?.topOfPage(page)
        } onClose: { [weak self] in
            guard let self, !draft.isCancelled else { return }
            setPageNote(draft.text, onPage: index)
        }
    }

    /// A spot near the top of the page's visible part, for a popover.
    private func topOfPage(_ page: PDFPage) -> CGRect? {
        guard pdfView.visiblePages.contains(page) else { return nil }
        let shown = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page).intersection(pdfView.bounds)
        guard !shown.isNull, shown.height > 40 else { return nil }
        let y = pdfView.isFlipped ? shown.minY + 28 : shown.maxY - 28
        return CGRect(x: shown.midX - 1, y: y, width: 2, height: 2)
    }

    /// Saves what she typed as the page's note: adds the note, changes it,
    /// or deletes it when the text is empty. Undo puts it back.
    func setPageNote(_ text: String, onPage index: Int) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pageNoteDraftPage == index { pageNoteDraftPage = nil }
        if let note = pageNote(onPage: index) {
            if text.isEmpty {
                deletePageNote(note)
            } else if text != note.text {
                changePageNote(id: note.id, to: text)
            }
        } else if !text.isEmpty, entry != nil, (0..<pageCount).contains(index) {
            insertPageNote(
                PageNoteSnapshot(id: UUID(), pageIndex: index, pageLabel: storedPageLabel(at: index), text: text, createdAt: .now),
                actionName: "Add Page Note"
            )
        }
    }

    func deletePageNote(_ note: PageNote) {
        removePageNote(id: note.id, actionName: "Delete Page Note")
    }

    private func insertPageNote(_ snapshot: PageNoteSnapshot, actionName: String) {
        guard let entry, let store else { return }
        store.addPageNote(
            to: entry, pageIndex: snapshot.pageIndex, pageLabel: snapshot.pageLabel, text: snapshot.text,
            id: snapshot.id, createdAt: snapshot.createdAt
        )
        refreshPageNotes()
        registerUndo(actionName) { $0.removePageNote(id: snapshot.id, actionName: actionName) }
    }

    private func removePageNote(id: UUID, actionName: String) {
        guard let note = pageNotes.first(where: { $0.id == id }) else { return }
        let snapshot = PageNoteSnapshot(note)
        store?.delete(note)
        refreshPageNotes()
        registerUndo(actionName) { $0.insertPageNote(snapshot, actionName: actionName) }
    }

    private func changePageNote(id: UUID, to text: String) {
        guard let note = pageNotes.first(where: { $0.id == id }) else { return }
        let old = note.text
        store?.setText(text, for: note)
        refreshPageNotes()
        registerUndo("Edit Page Note") { $0.changePageNote(id: id, to: old) }
    }

    // MARK: Summary

    /// "My summary" of this PDF.
    var summary: String { entry?.summary ?? "" }

    /// Saves the summary. Undo puts back what it was.
    func setSummary(_ text: String) {
        guard let entry, let store else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = entry.summary
        guard text != old else { return }
        store.setSummary(text, for: entry)
        registerUndo("Edit Summary") { $0.setSummary(old) }
    }

    // MARK: Quoting

    /// “highlighted text” (Title, p. 245)
    func quote(for record: HighlightRecord) -> String {
        Citation.quote(record.text, title: title, page: pageLabel(at: record.pageIndex))
    }

    /// What Copy as Quote copies: the text selected on the page, else the
    /// highlight clicked or just made, else the one made last.
    var quoteToCopy: String? {
        if let selection = pdfView.currentSelection,
           let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let pages = selection.pages.map { document.index(for: $0) }
            return Citation.quote(
                text, title: title,
                firstPage: pageLabel(at: pages.min() ?? 0), lastPage: pageLabel(at: pages.max() ?? 0)
            )
        }
        return targetHighlight.map(quote(for:))
    }

    /// Edit › Copy as Quote. Returns false when there's nothing to quote.
    @discardableResult
    func copyQuote(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let quote = quoteToCopy else { return false }
        Citation.copy(quote, to: pasteboard)
        return true
    }

    // MARK: The Highlights panel

    /// One page in the Highlights panel: its note (or an empty one being
    /// written) and its highlights, after the color filter.
    struct PanelGroup {
        let page: Int
        let note: PageNote?
        /// Shows an empty note to type in.
        let hasDraftNote: Bool
        let items: [HighlightRecord]
    }

    /// The panel's pages, in order. Page notes have no color, so a color
    /// filter hides them.
    var panelGroups: [PanelGroup] {
        let shown = panelFilter.isEmpty ? highlights : highlights.filter { panelFilter.contains($0.kind) }
        let byPage = Dictionary(grouping: shown, by: \.pageIndex)
        let notes = panelFilter.isEmpty ? pageNotes : []
        var pages = Set(byPage.keys).union(notes.map(\.pageIndex))
        if let draft = pageNoteDraftPage { pages.insert(draft) }
        return pages.sorted().map { page in
            let note = notes.first { $0.pageIndex == page }
            return PanelGroup(page: page, note: note, hasDraftNote: note == nil && pageNoteDraftPage == page, items: byPage[page] ?? [])
        }
    }
}
