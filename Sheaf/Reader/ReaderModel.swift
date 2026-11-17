import AppKit
import CoreImage
import Observation
import PDFKit

/// The state of one reader tab: the PDF, the PDFKit view that shows it,
/// the page, zoom, layout, search and highlights. The header, panels and
/// menus all call into this, so they stay in sync.
@Observable
final class ReaderModel {
    enum PageLayout: String, CaseIterable, Identifiable {
        case single
        case twoPages
        case scroll
        case twoPageScroll

        var id: Self { self }

        var title: String {
            switch self {
            case .single: "Single"
            case .twoPages: "Two pages"
            case .scroll: "Scroll"
            case .twoPageScroll: "Two-page scroll"
            }
        }

        var menuTitle: String {
            switch self {
            case .single: "Single Page"
            case .twoPages: "Two Pages"
            case .scroll: "Continuous Scroll"
            case .twoPageScroll: "Two Pages, Continuous Scroll"
            }
        }

        /// Pages side by side, in pairs.
        var showsPairs: Bool { self == .twoPages || self == .twoPageScroll }
    }

    /// How the page is sized in the window.
    enum ZoomMode: String {
        /// The whole page (or pair of pages) fits in the window.
        case fitPage
        /// The page is as wide as the window; scroll to see the rest.
        case fitWidth
        /// A size the reader picked: Actual Size, zooming in or out, pinching.
        case custom
    }

    let document: PDFDocument
    /// Created once and kept, so the page view survives SwiftUI updates.
    @ObservationIgnored let pdfView = SheafPDFView()
    let outline: [OutlineItem]
    /// The table of contents as a flat, indented list for the Contents view.
    let outlineRows: [OutlineRow]
    /// The library entry for this PDF: reading position and highlights.
    @ObservationIgnored let entry: LibraryEntry?
    @ObservationIgnored private let store: LibraryStore?
    @ObservationIgnored let fileURL: URL?

    private(set) var currentPageIndex = 0
    private(set) var zoomPercent = 100
    /// Fit page, fit width, or a size the reader picked. The fit modes are
    /// remembered for the next PDF.
    private(set) var zoomMode = ZoomMode.fitPage
    var pageCount: Int { document.pageCount }

    /// Single, two pages or scroll. Remembered for the next PDF.
    var layout = PageLayout.scroll {
        didSet {
            applyLayout()
            preferences.set(layout.rawValue, forKey: Self.layoutKey)
        }
    }

    /// In the two-page layouts, shows the cover on its own so the pages
    /// after it pair up like a printed book's. Remembered for the next PDF.
    var showsBookSpreads = false {
        didSet {
            applyLayout()
            preferences.set(showsBookSpreads, forKey: Self.bookSpreadsKey)
        }
    }

    static let layoutKey = "pageLayout"
    static let zoomModeKey = "zoomMode"
    static let bookSpreadsKey = "bookSpreads"
    /// Dark pages with light text while the Mac is in Dark Mode.
    static let darkPagesKey = "darkPages"
    @ObservationIgnored private let preferences: UserDefaults
    /// The scale Sheaf last set for a fit mode, to tell it apart from the
    /// reader zooming (which switches to `.custom`).
    @ObservationIgnored private var fittedScale: CGFloat?

    var isGoToPagePresented = false
    var isSearchBarVisible = false
    /// Incremented to move keyboard focus into the search field.
    var searchFocusRequest = 0

    // MARK: Highlight state

    /// The highlighter in use. While one is picked, selecting text highlights it.
    var activePen: HighlightKind?
    private(set) var highlights: [HighlightRecord] = []
    /// Kinds shown in the Highlights panel. Empty means all.
    var panelFilter = Set<HighlightKind>()
    /// Set when writing highlights into the file failed.
    private(set) var saveError: String?
    /// Why highlights are kept in Sheaf only, if this file can't be rewritten.
    private(set) var fileWriteBlock: FileWriteBlock?
    /// The window's undo manager, set by the reader view.
    @ObservationIgnored weak var undoManager: UndoManager?

    enum FileWriteBlock {
        case passwordProtected
        case signed

        var explanation: String {
            switch self {
            case .passwordProtected:
                "This PDF is password-protected, so highlights are kept in Sheaf\u{2019}s library and not written into the file."
            case .signed:
                "This PDF is digitally signed, so highlights are kept in Sheaf\u{2019}s library and not written into the file (that would break the signature)."
            }
        }
    }

    // MARK: Search state

    var searchQuery = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var selectedResultID: SearchResult.ID?
    var isShowingSearchResults: Bool { isSearchBarVisible && !normalizedQuery.isEmpty }

    // MARK: Private

    @ObservationIgnored private var hasRestoredPosition = false
    @ObservationIgnored private var activeQuery = ""
    @ObservationIgnored private var seenMatches = Set<MatchKey>()
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(
        document: PDFDocument, entry: LibraryEntry?, store: LibraryStore?, fileURL: URL?,
        preferences: UserDefaults = .standard
    ) {
        self.document = document
        self.entry = entry
        self.store = store
        self.fileURL = fileURL
        self.preferences = preferences
        self.outline = OutlineItem.items(under: document.outlineRoot)
        self.outlineRows = OutlineRow.flatten(outline, in: document)
        if let saved = preferences.string(forKey: Self.layoutKey), let layout = PageLayout(rawValue: saved) {
            self.layout = layout
        }
        self.showsBookSpreads = preferences.bool(forKey: Self.bookSpreadsKey)
        if let saved = preferences.string(forKey: Self.zoomModeKey), let mode = ZoomMode(rawValue: saved), mode != .custom {
            self.zoomMode = mode
        } else if !self.layout.showsPairs && self.layout != .single {
            // Scrolling pages have always filled the width; keep that until the reader picks otherwise.
            self.zoomMode = .fitWidth
        }

        pdfView.autoScales = false
        pdfView.displaysPageBreaks = true
        pdfView.document = document
        applyLayout()
        applyPageColors()

        pdfView.onMouseUp = { [weak self] in self?.mouseUpInPage() }
        pdfView.onHighlightKey = { [weak self] kind in self?.highlightKeyPressed(kind) ?? false }
        pdfView.onAppearanceChange = { [weak self] in self?.applyPageColors() }

        if document.isEncrypted {
            fileWriteBlock = .passwordProtected
        }
        refreshHighlights()
        if PDFHighlights.restoreMissing(highlights, in: document) > 0 {
            scheduleSave()
        }
        observeNotifications()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var title: String {
        entry?.title ?? fileURL?.deletingPathExtension().lastPathComponent ?? "PDF"
    }

    /// Call once the page view is on screen. Jumps to where the reader left off.
    func restoreReadingPosition() {
        guard !hasRestoredPosition else { return }
        hasRestoredPosition = true
        guard let index = entry?.lastPageIndex, index > 0, index < pageCount,
              let page = document.page(at: index)
        else { return }
        pdfView.layoutDocumentView()
        pdfView.go(to: page)
    }

    /// Call when the PDF is closed.
    func close() {
        document.cancelFindString()
        flushPendingSave()
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Call when the reader leaves the screen: saves now, and drops undo
    /// steps so ⌘Z elsewhere can't change this PDF unseen.
    func suspend() {
        flushPendingSave()
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: Pages

    /// The pages on screen: one, or a pair in the two-page layouts. With book
    /// spreads the cover is alone and pairs start on even page numbers.
    var visiblePageIndices: [Int] {
        guard pageCount > 0 else { return [] }
        guard layout.showsPairs else { return [currentPageIndex] }
        let first: Int
        if showsBookSpreads {
            if currentPageIndex == 0 { return [0] }
            first = currentPageIndex.isMultiple(of: 2) ? currentPageIndex - 1 : currentPageIndex
        } else {
            first = currentPageIndex.isMultiple(of: 2) ? currentPageIndex : currentPageIndex - 1
        }
        return first + 1 < pageCount ? [first, first + 1] : [first]
    }

    var canGoToPreviousPage: Bool { (visiblePageIndices.first ?? 0) > 0 }
    var canGoToNextPage: Bool { (visiblePageIndices.last ?? 0) < pageCount - 1 }

    /// "4" or, for a pair of pages, "4–5".
    var pageLabel: String {
        let pages = visiblePageIndices
        guard let first = pages.first, let last = pages.last else { return "0" }
        return first == last ? String(first + 1) : "\(first + 1)\u{2013}\(last + 1)"
    }

    func goToPreviousPage() { pdfView.goToPreviousPage(nil) }
    func goToNextPage() { pdfView.goToNextPage(nil) }

    /// Goes to a 1-based page number, as people type it.
    func goToPage(number: Int) {
        guard (1...max(pageCount, 1)).contains(number), let page = document.page(at: number - 1) else { return }
        pdfView.go(to: page)
    }

    func go(to item: OutlineItem) {
        guard let destination = item.destination else { return }
        pdfView.go(to: destination)
    }

    func go(to row: OutlineRow) {
        if let destination = row.destination {
            pdfView.go(to: destination)
        } else if let index = row.pageIndex, let page = document.page(at: index) {
            pdfView.go(to: page)
        }
    }

    /// The contents entry for the section being read: the last one that
    /// starts on or before the current page.
    var currentOutlineRowID: OutlineRow.ID? {
        outlineRows.last { ($0.pageIndex ?? .max) <= currentPageIndex }?.id
    }

    // MARK: Zoom

    func zoomIn() {
        setZoomMode(.custom)
        pdfView.zoomIn(nil)
    }

    func zoomOut() {
        setZoomMode(.custom)
        pdfView.zoomOut(nil)
    }

    func zoomToActualSize() {
        setZoomMode(.custom)
        pdfView.scaleFactor = 1
    }

    /// The whole page, or pair of pages, fits in the window.
    func zoomToFit() { setZoomMode(.fitPage) }

    /// The page fills the window's width.
    func zoomToWidth() { setZoomMode(.fitWidth) }

    private func setZoomMode(_ mode: ZoomMode) {
        zoomMode = mode
        if mode != .custom {
            preferences.set(mode.rawValue, forKey: Self.zoomModeKey)
        }
        applyZoom()
    }

    /// Sizes the page for the fit modes. Runs again when the window or the
    /// layout changes, so the page keeps fitting.
    func applyZoom() {
        guard zoomMode != .custom,
              let page = pdfView.currentPage ?? document.page(at: 0)
        else { return }
        let available = pdfView.bounds.size
        guard available.width > 40, available.height > 40 else { return }

        var pageSize = page.bounds(for: pdfView.displayBox).size
        if page.rotation % 180 != 0 {
            pageSize = CGSize(width: pageSize.height, height: pageSize.width)
        }
        guard pageSize.width > 0, pageSize.height > 0 else { return }

        // Room for the gap around the pages, and between a pair of pages.
        let margin: CGFloat = 16
        let columns: CGFloat = layout.showsPairs ? 2 : 1
        let widthScale = (available.width - margin * (columns + 1)) / (pageSize.width * columns)
        let heightScale = (available.height - margin * 2) / pageSize.height
        let scale = zoomMode == .fitWidth ? widthScale : min(widthScale, heightScale)

        let clamped = min(max(scale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        fittedScale = clamped
        guard abs(pdfView.scaleFactor - clamped) > 0.001 else { return }
        // Keep the reader's place: rescaling alone would scroll to a different page.
        let place = pdfView.currentDestination
        pdfView.scaleFactor = clamped
        if let place { pdfView.go(to: place) }
        scaleDidChange()
    }

    private func applyLayout() {
        switch layout {
        case .single: pdfView.displayMode = .singlePage
        case .twoPages: pdfView.displayMode = .twoUp
        case .scroll: pdfView.displayMode = .singlePageContinuous
        case .twoPageScroll: pdfView.displayMode = .twoUpContinuous
        }
        pdfView.displaysAsBook = showsBookSpreads
        applyZoom()
    }

    // MARK: Page colors

    /// With "Dark Pages" on and the Mac in Dark Mode, pages turn dark gray
    /// with light gray text. The colors are inverted, turned back around the
    /// color wheel so highlights keep their hue (yellow stays yellowish), and
    /// softened so the page isn't pure black and the text not pure white.
    func applyPageColors() {
        let isDarkMode = pdfView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let isDarkPages = isDarkMode && preferences.bool(forKey: Self.darkPagesKey)
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        if isDarkPages, let filters = Self.darkPageFilters() {
            pdfView.contentFilters = filters
            // The filters apply to the background too: near-white comes out
            // a dark gray just lighter than the pages.
            pdfView.backgroundColor = NSColor(hex: 0xFEFEFE)
            // Inverted, page shadows would glow.
            pdfView.pageShadowsEnabled = false
        } else {
            pdfView.contentFilters = []
            pdfView.backgroundColor = NSColor(hex: isDarkMode ? 0x0F0F0F : 0xF0F0F0)
            pdfView.pageShadowsEnabled = true
        }
    }

    private static func darkPageFilters() -> [CIFilter]? {
        guard let invert = CIFilter(name: "CIColorInvert"),
              let hue = CIFilter(name: "CIHueAdjust"),
              let soften = CIFilter(name: "CIColorMatrix")
        else { return nil }
        hue.setValue(Double.pi, forKey: kCIInputAngleKey)
        // Core Image works in linear light: white text ends near #D8D8D8,
        // the black page near #1E1E1E.
        let scale: CGFloat = 0.673, lift: CGFloat = 0.013
        soften.setValue(CIVector(x: scale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        soften.setValue(CIVector(x: 0, y: scale, z: 0, w: 0), forKey: "inputGVector")
        soften.setValue(CIVector(x: 0, y: 0, z: scale, w: 0), forKey: "inputBVector")
        soften.setValue(CIVector(x: lift, y: lift, z: lift, w: 0), forKey: "inputBiasVector")
        return [invert, hue, soften]
    }

    // MARK: Highlighting

    /// Picks a highlighter. With text selected, highlights it right away.
    /// Picking the active highlighter again turns highlighting off.
    func choosePen(_ kind: HighlightKind) {
        if highlightSelection(as: kind) {
            activePen = kind
        } else {
            activePen = activePen == kind ? nil : kind
        }
    }

    /// Highlights the selected text. Returns false if nothing is selected.
    @discardableResult
    func highlightSelection(as kind: HighlightKind) -> Bool {
        guard let selection = pdfView.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entry, let store
        else { return false }

        let lines = selection.selectionsByLine()
        var created: [HighlightSnapshot] = []
        for page in selection.pages {
            let pageLines = lines.filter { $0.pages.contains(page) }
            let rects = pageLines.map { $0.bounds(for: page) }.filter { $0.width > 0.5 && $0.height > 0.5 }
            guard !rects.isEmpty else { continue }
            let text = pageLines
                .compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let record = store.addHighlight(
                to: entry, pageIndex: document.index(for: page), kind: kind, text: text, rects: rects
            )
            PDFHighlights.add(record, to: document)
            created.append(HighlightSnapshot(record))
        }
        guard !created.isEmpty else { return false }
        pdfView.clearSelection()
        refreshHighlights()
        scheduleSave()
        registerUndo("Highlight") { $0.removeHighlights(created, actionName: "Highlight") }
        return true
    }

    func setNote(_ note: String, for record: HighlightRecord) {
        let old = record.note
        let id = record.id
        guard note.trimmingCharacters(in: .whitespacesAndNewlines) != old else { return }
        store?.setNote(note, for: record)
        PDFHighlights.update(record, in: document)
        refreshHighlights()
        scheduleSave()
        registerUndo("Edit Note") { model in
            if let record = model.highlight(id: id) { model.setNote(old, for: record) }
        }
    }

    func setKind(_ kind: HighlightKind, for record: HighlightRecord) {
        let old = record.kind
        let id = record.id
        guard kind != old else { return }
        store?.setKind(kind, for: record)
        PDFHighlights.update(record, in: document)
        refreshHighlights()
        scheduleSave()
        registerUndo("Change Highlight Color") { model in
            if let record = model.highlight(id: id) { model.setKind(old, for: record) }
        }
    }

    func delete(_ record: HighlightRecord) {
        removeHighlights([HighlightSnapshot(record)], actionName: "Delete Highlight")
    }

    func highlight(id: UUID) -> HighlightRecord? {
        highlights.first { $0.id == id }
    }

    /// Removes highlights; Undo puts them back with the same IDs.
    private func removeHighlights(_ snapshots: [HighlightSnapshot], actionName: String) {
        for snapshot in snapshots {
            PDFHighlights.remove(snapshot.id, from: document)
            if let record = highlight(id: snapshot.id) { store?.delete(record) }
        }
        refreshHighlights()
        scheduleSave()
        registerUndo(actionName) { $0.restoreHighlights(snapshots, actionName: actionName) }
    }

    private func restoreHighlights(_ snapshots: [HighlightSnapshot], actionName: String) {
        guard let entry, let store else { return }
        for snapshot in snapshots {
            store.restoreHighlight(snapshot, to: entry)
            PDFHighlights.add(snapshot, to: document)
        }
        refreshHighlights()
        scheduleSave()
        registerUndo(actionName) { $0.removeHighlights(snapshots, actionName: actionName) }
    }

    private func registerUndo(_ actionName: String, _ action: @escaping (ReaderModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { action($0) }
        undoManager.setActionName(actionName)
    }

    func go(to record: HighlightRecord) {
        guard let page = document.page(at: record.pageIndex) else { return }
        if let rect = record.rects.first {
            pdfView.go(to: rect.insetBy(dx: 0, dy: -40), on: page)
        } else {
            pdfView.go(to: page)
        }
    }

    func count(of kind: HighlightKind) -> Int {
        highlights.count { $0.kind == kind }
    }

    /// Highlights for the panel, grouped by page, after the color filter.
    var highlightGroups: [(page: Int, items: [HighlightRecord])] {
        let shown = panelFilter.isEmpty ? highlights : highlights.filter { panelFilter.contains($0.kind) }
        return Dictionary(grouping: shown, by: \.pageIndex)
            .sorted { $0.key < $1.key }
            .map { (page: $0.key, items: $0.value) }
    }

    /// Where highlights sit on a page, from 0 (top) to 1 (bottom), for the
    /// markers beside each thumbnail.
    func markers(onPage index: Int) -> [(position: Double, kind: HighlightKind)] {
        guard let page = document.page(at: index) else { return [] }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.height > 0 else { return [] }
        return highlights.filter { $0.pageIndex == index }.map { record in
            let position = 1 - (record.top - bounds.minY) / bounds.height
            return (position: min(max(position, 0), 1), kind: record.kind)
        }
    }

    /// All highlights as Markdown, grouped by meaning.
    func markdownExport() -> String {
        var lines = ["# \(title)", ""]
        for kind in HighlightKind.allCases {
            let items = highlights.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            lines.append("## \(kind.name)")
            lines.append("")
            for item in items {
                lines.append("- \u{201C}\(item.text)\u{201D} (p. \(item.pageIndex + 1))")
                if !item.note.isEmpty {
                    lines.append("  - \(item.note)")
                }
            }
            lines.append("")
        }
        if highlights.isEmpty {
            lines.append("No highlights yet.")
        }
        return lines.joined(separator: "\n")
    }

    private func refreshHighlights() {
        highlights = (entry?.highlights ?? []).sorted {
            ($0.pageIndex, -$0.top) < ($1.pageIndex, -$1.top)
        }
    }

    private func mouseUpInPage() {
        if let activePen {
            highlightSelection(as: activePen)
        }
    }

    /// Keys 1–4 in the page: highlight the selection, or pick that highlighter.
    private func highlightKeyPressed(_ kind: HighlightKind) -> Bool {
        if !highlightSelection(as: kind) {
            activePen = activePen == kind ? nil : kind
        }
        return true
    }

    // MARK: Saving into the PDF

    /// Writes highlights into the file shortly after the last change, so a
    /// burst of highlighting causes one save.
    private func scheduleSave() {
        hasUnsavedChanges = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.startSave()
        }
    }

    /// Starts saving now instead of after the usual pause.
    func flushPendingSave() {
        debounceTask?.cancel()
        startSave()
    }

    /// Saves now and waits until the file is written.
    func saveAndWait() async {
        flushPendingSave()
        await saveChain?.value
    }

    /// Saves run one after another on a background thread: writing a long
    /// PDF can take several seconds, and reading must not freeze meanwhile.
    private func startSave() {
        guard hasUnsavedChanges, let fileURL, fileWriteBlock == nil else { return }
        hasUnsavedChanges = false
        let snapshots = highlights.map(HighlightSnapshot.init)
        let previous = saveChain
        let task = Task { [weak self] in
            await previous?.value
            let outcome = await Task.detached(priority: .utility) {
                PDFHighlightWriter.write(snapshots, to: fileURL)
            }.value
            self?.finishSave(outcome, fileName: fileURL.lastPathComponent)
        }
        saveChain = task
        SaveTracker.shared.track(task)
    }

    private func finishSave(_ outcome: PDFHighlightWriter.Outcome, fileName: String) {
        switch outcome {
        case .saved:
            saveError = nil
        case .signed:
            fileWriteBlock = .signed
            saveError = nil
        case .passwordProtected:
            fileWriteBlock = .passwordProtected
            saveError = nil
        case .failed:
            saveError = "Couldn\u{2019}t save highlights into \u{201C}\(fileName)\u{201D}. They\u{2019}re still kept in Sheaf\u{2019}s library."
        }
    }

    // MARK: Search

    /// Starts a new search for `searchQuery`, replacing any search in progress.
    /// Results arrive a page at a time, so long documents stay responsive.
    func search() {
        let query = normalizedQuery
        guard query != activeQuery else { return }

        document.cancelFindString()
        activeQuery = query
        searchResults = []
        seenMatches = []
        selectedResultID = nil
        pdfView.highlightedSelections = nil

        guard !query.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        document.beginFindString(query, withOptions: [.caseInsensitive])
    }

    func closeSearch() {
        searchQuery = ""
        search()
        isSearchBarVisible = false
    }

    func selectResult(id: SearchResult.ID) {
        guard searchResults.indices.contains(id) else { return }
        let result = searchResults[id]
        selectedResultID = id
        pdfView.setCurrentSelection(result.selection, animate: true)
        pdfView.go(to: result.selection)
    }

    func selectNextResult() {
        guard !searchResults.isEmpty else { return }
        let next = selectedResultID.map { ($0 + 1) % searchResults.count } ?? 0
        selectResult(id: next)
    }

    func selectPreviousResult() {
        guard !searchResults.isEmpty else { return }
        let count = searchResults.count
        let previous = selectedResultID.map { ($0 - 1 + count) % count } ?? count - 1
        selectResult(id: previous)
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func didFind(_ selection: PDFSelection) {
        // A search that was just cancelled can still deliver a few matches;
        // keep only ones that fit the current query, once each.
        guard !activeQuery.isEmpty,
              let text = selection.string,
              text.range(of: activeQuery, options: .caseInsensitive) != nil,
              let page = selection.pages.first
        else { return }

        let pageIndex = document.index(for: page)
        guard seenMatches.insert(MatchKey(pageIndex: pageIndex, bounds: selection.bounds(for: page))).inserted else { return }

        selection.color = .findHighlightColor
        searchResults.append(SearchResult(
            id: searchResults.count,
            selection: selection,
            pageLabel: page.label ?? String(pageIndex + 1),
            snippet: Self.snippet(around: selection, query: activeQuery)
        ))
    }

    private func refreshSearchHighlights() {
        if pdfView.highlightedSelections?.count != searchResults.count {
            pdfView.highlightedSelections = searchResults.map(\.selection)
        }
    }

    /// The line of text around a match, with the match in bold.
    private static func snippet(around selection: PDFSelection, query: String) -> AttributedString {
        guard let line = selection.copy() as? PDFSelection else { return AttributedString(selection.string ?? "") }
        line.extendForLineBoundaries()
        let text = (line.string ?? "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        var snippet = AttributedString(text)
        if let range = snippet.range(of: query, options: .caseInsensitive) {
            snippet[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return snippet
    }

    // MARK: Notifications

    private func pageDidChange() {
        guard let page = pdfView.currentPage else { return }
        currentPageIndex = document.index(for: page)
        // Don't overwrite the saved page with page 1 while the tab is still opening.
        if hasRestoredPosition {
            entry?.recordPage(currentPageIndex)
        }
    }

    private func scaleDidChange() {
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
        // A scale Sheaf didn't set for a fit mode means the reader zoomed (by pinching, say).
        if zoomMode != .custom, let fittedScale, abs(pdfView.scaleFactor - fittedScale) > 0.001 {
            zoomMode = .custom
        }
    }

    private func frameDidChange() {
        applyZoom()
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        // All observers run on the main queue, so they can safely touch UI state.
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scaleDidChange() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.frameDidChange() }
            },
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
                nonisolated(unsafe) let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                MainActor.assumeIsolated {
                    if let selection { self?.didFind(selection) }
                }
            },
            center.addObserver(forName: .PDFDocumentDidEndPageFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSearchHighlights() }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSearching = self.document.isFinding
                    self.refreshSearchHighlights()
                }
            },
            center.addObserver(forName: .sheafFlushSaves, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingSave() }
            },
        ]
    }
}

/// One match in the search results list.
struct SearchResult: Identifiable {
    /// Position in the results list, which is also document order.
    let id: Int
    let selection: PDFSelection
    let pageLabel: String
    let snippet: AttributedString
}

struct MatchKey: Hashable {
    let pageIndex: Int
    let x: Double, y: Double, width: Double, height: Double

    init(pageIndex: Int, bounds: CGRect) {
        self.pageIndex = pageIndex
        x = bounds.origin.x
        y = bounds.origin.y
        width = bounds.width
        height = bounds.height
    }
}
