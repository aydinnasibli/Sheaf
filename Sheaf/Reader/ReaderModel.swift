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
    @ObservationIgnored let store: LibraryStore?
    @ObservationIgnored let fileURL: URL?
    /// Printed page labels ("xii", "245"), one per page, or none when the
    /// pages are just numbered 1, 2, 3…
    let pageLabels: [String]

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
    /// A short note over the page, such as why text can't be selected on a
    /// scanned page. It goes away by itself.
    private(set) var pageNotice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Box highlights whose words are still being read, by highlight.
    @ObservationIgnored private var boxReadings: [UUID: Task<Void, Never>] = [:]

    // MARK: Notes state

    /// The highlight clicked on the page, or the one just made. Its card in
    /// the Highlights panel is outlined, and Copy as Quote and the note
    /// shortcut act on it.
    var selectedHighlightID: UUID?
    /// Page notes, in page order.
    private(set) var pageNotes: [PageNote] = []
    /// A highlight whose card should start editing its note; the card
    /// clears it once it has.
    var pendingNoteEditID: UUID?
    /// A page whose note card should start editing; the card clears it.
    var pendingPageNoteEdit: Int?
    /// A page without a note where the panel shows an empty note to type in.
    var pageNoteDraftPage: Int?
    /// Whether the Highlights panel is on screen. When it isn't (focus mode,
    /// a narrow window, search results), notes open in a popover instead.
    @ObservationIgnored var isHighlightsPanelVisible = false
    /// The popover over the page for a highlight or a page note.
    @ObservationIgnored let popover = PagePopover()

    // MARK: Reading progress

    @ObservationIgnored private var progress = ReadingProgress()
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    /// How long a page she jumped to stays on screen before it counts as
    /// read: long enough that a quick look at a reference doesn't.
    @ObservationIgnored var readingDwell: Duration = .seconds(10)

    static let scannedPageNotice = "This page is a scanned image, so its text can\u{2019}t be selected. Drag a box to highlight an area."
    /// The text of a box highlight when no words are found in the box.
    static let imageAreaText = "Image area"

    enum FileWriteBlock {
        case passwordProtected
        case signed
        /// The library couldn't be opened, so this session nothing is
        /// written into PDF files.
        case temporaryLibrary

        var explanation: String {
            switch self {
            case .passwordProtected:
                "This PDF is password-protected, so highlights are kept in Sheaf\u{2019}s library and not written into the file."
            case .signed:
                "This PDF is digitally signed, so highlights are kept in Sheaf\u{2019}s library and not written into the file (that would break the signature)."
            case .temporaryLibrary:
                "Sheaf couldn\u{2019}t open your library, so this time nothing is written into PDF files, and new highlights are kept only until Sheaf quits."
            }
        }
    }

    // MARK: Search state

    var searchQuery = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var selectedResultID: SearchResult.ID?
    var isShowingSearchResults: Bool { isSearchBarVisible && !normalizedQuery.isEmpty }
    /// Searching stopped at `searchResultLimit` matches; there are more.
    private(set) var hasMoreResults = false

    /// The most matches listed. Past this, searching stops: no one reads a
    /// thousand matches, and finding more would slow the reader down.
    static let searchResultLimit = 1000

    // MARK: Scanned pages and thumbnails

    /// Pages that are scanned images, and the text read off them for search.
    @ObservationIgnored let scannedPages = ScannedPages()
    /// Tells this PDF's thumbnails apart from other PDFs' in the shared cache.
    @ObservationIgnored let thumbnailCacheID = UUID()
    @ObservationIgnored private var backgroundCopy: PageRenderer?

    /// A second copy of the PDF for thumbnails and reading scanned pages
    /// away from the main thread, made on first use.
    var renderer: PageRenderer {
        if let backgroundCopy { return backgroundCopy }
        // Readers in the app always have a file; tests may not.
        let source = fileURL.map(PageRenderer.Source.file) ?? .data(document.dataRepresentation() ?? Data())
        let renderer = PageRenderer(source: source, expectedPageCount: pageCount)
        backgroundCopy = renderer
        return renderer
    }

    // MARK: Private

    @ObservationIgnored private var hasRestoredPosition = false
    @ObservationIgnored private var activeQuery = ""
    @ObservationIgnored private var seenMatches = Set<MatchKey>()
    /// Text matches PDFKit has reported, in document order.
    @ObservationIgnored private var textMatches: [FoundMatch] = []
    /// Text matches not yet listed: they're shown a batch at a time.
    @ObservationIgnored private var pendingMatches: [FoundMatch] = []
    /// Matches in text read off scanned pages, by page.
    @ObservationIgnored private var recognizedMatches: [Int: [FoundMatch]] = [:]
    /// The last page PDFKit has searched. Matches on scanned pages after it
    /// wait, so the list fills in document order.
    @ObservationIgnored private var searchedThroughPage = -1
    @ObservationIgnored private var lastResultsUpdate = ContinuousClock.now
    /// Snippets made so far; each is made when its row first shows.
    @ObservationIgnored private var snippets: [MatchKey: AttributedString] = [:]
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
        // Saving highlights into a PDF loses its page labels, so the library
        // remembers them from when the file still had them.
        let ownLabels = PageLabels.read(from: document)
        let remembered = entry?.pageLabels ?? []
        self.pageLabels = ownLabels.isEmpty && remembered.count == document.pageCount ? remembered : ownLabels
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
        pdfView.onFollowLink = { [weak self] in self?.rememberPlace() }
        pdfView.onPageClick = { [weak self] page, point in self?.pageClicked(page, at: point) }
        bookmarks = entry?.bookmarkedPages ?? []
        if !ownLabels.isEmpty, let entry, entry.pageLabels != ownLabels {
            entry.pageLabels = ownLabels
            store?.save()
        }
        refreshPageNotes()

        if document.isEncrypted {
            fileWriteBlock = .passwordProtected
        }
        if store?.isTemporaryLibrary == true {
            fileWriteBlock = .temporaryLibrary
        }
        refreshHighlights()
        // Changes that didn't reach the file last time are saved now.
        if PDFHighlights.bringUpToDate(document, with: highlights, removedIDs: entry?.removedHighlightIDs ?? [])
            || entry?.needsFileSave == true {
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
        // Reading on from here counts if this page was read.
        defer { startTrackingProgress() }
        guard let index = entry?.lastPageIndex, index > 0, index < pageCount,
              let page = document.page(at: index)
        else { return }
        pdfView.layoutDocumentView()
        pdfView.go(to: page)
    }

    /// Call when the PDF is closed.
    func close() {
        popover.close()
        dwellTask?.cancel()
        stopBackgroundWork()
        document.cancelFindString()
        flushPendingSave()
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Call when the reader leaves the screen: saves now, and drops undo
    /// steps so ⌘Z elsewhere can't change this PDF unseen.
    func suspend() {
        // First, so a note typed in the popover is kept.
        popover.close()
        dwellTask?.cancel()
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

    /// The pages on screen as printed: "xii", "4" or, for a pair, "4–5".
    var pageLabel: String {
        let pages = visiblePageIndices
        guard let first = pages.first, let last = pages.last else { return "0" }
        return first == last ? pageLabel(at: first) : "\(pageLabel(at: first))\u{2013}\(pageLabel(at: last))"
    }

    /// The pages on screen by position, counting from 1: "14" or "14–15".
    var pagePosition: String {
        let pages = visiblePageIndices
        guard let first = pages.first, let last = pages.last else { return "0" }
        return first == last ? String(first + 1) : "\(first + 1)\u{2013}\(last + 1)"
    }

    /// The page's printed label ("xii", "245"), or its number when the PDF
    /// has no labels.
    func pageLabel(at index: Int) -> String {
        pageLabels.indices.contains(index) ? pageLabels[index] : String(index + 1)
    }

    /// The printed label to keep with a highlight or page note, or "" when
    /// the PDF has none (the number is shown then).
    func storedPageLabel(at index: Int) -> String {
        pageLabels.indices.contains(index) ? pageLabels[index] : ""
    }

    /// What Go to Page asks for.
    var goToPagePrompt: String {
        guard !pageLabels.isEmpty else { return "Enter a page number from 1 to \(pageCount)." }
        return "Enter a page number as it\u{2019}s printed, like \u{201C}\(pageLabel(at: currentPageIndex))\u{201D}, or a page from 1 to \(pageCount) counting from the start."
    }

    func goToPreviousPage() { pdfView.goToPreviousPage(nil) }
    func goToNextPage() { pdfView.goToNextPage(nil) }

    /// Goes to the page typed in Go to Page: its printed label ("xii",
    /// "245") or its number counting from 1. Returns false if there's no
    /// such page.
    @discardableResult
    func goToPage(typed: String) -> Bool {
        guard let index = PageLabels.pageIndex(for: typed, labels: pageLabels, pageCount: pageCount) else { return false }
        goToPage(number: index + 1)
        return true
    }

    /// Goes to a 1-based page number, as people type it.
    func goToPage(number: Int) {
        guard (1...max(pageCount, 1)).contains(number), let page = document.page(at: number - 1) else { return }
        rememberPlace()
        pdfView.go(to: page)
    }

    func go(to item: OutlineItem) {
        guard let destination = item.destination else { return }
        rememberPlace()
        pdfView.go(to: destination)
    }

    func go(to row: OutlineRow) {
        if let destination = row.destination {
            rememberPlace()
            pdfView.go(to: destination)
        } else if let index = row.pageIndex, let page = document.page(at: index) {
            rememberPlace()
            pdfView.go(to: page)
        }
    }

    // MARK: Back and forward

    /// Where the reader was before each jump: a link in the PDF, the
    /// contents, a thumbnail, Go to Page, a search result or a highlight.
    /// Turning pages and scrolling aren't jumps. (PDFKit's own history counts
    /// every page turn, so Sheaf keeps its own.)
    private var backPlaces: [PDFDestination] = []
    private var forwardPlaces: [PDFDestination] = []

    var canGoBack: Bool { !backPlaces.isEmpty }
    var canGoForward: Bool { !forwardPlaces.isEmpty }

    /// The page Back returns to (1-based), for the Back button.
    var backPageNumber: Int? {
        backPlaces.last?.page.map { document.index(for: $0) + 1 }
    }

    /// The page Back returns to as printed, for the Back button.
    var backPageLabel: String? {
        backPageNumber.map { pageLabel(at: $0 - 1) }
    }

    /// Call just before a jump, so Back can return here.
    func rememberPlace() {
        // Where it lands doesn't count as read yet.
        progress.jumpStarting()
        guard hasRestoredPosition, let here = pdfView.currentDestination else { return }
        backPlaces.append(here)
        if backPlaces.count > 50 { backPlaces.removeFirst() }
        forwardPlaces.removeAll()
    }

    func goBack() {
        guard let place = backPlaces.popLast() else { return }
        progress.jumpStarting()
        if let here = pdfView.currentDestination { forwardPlaces.append(here) }
        pdfView.go(to: place)
    }

    func goForward() {
        guard let place = forwardPlaces.popLast() else { return }
        progress.jumpStarting()
        if let here = pdfView.currentDestination { backPlaces.append(here) }
        pdfView.go(to: place)
    }

    // MARK: Bookmarks

    /// Bookmarked pages (0-based), in order.
    private(set) var bookmarks: [Int] = []

    var isCurrentPageBookmarked: Bool { bookmarks.contains(currentPageIndex) }

    /// Bookmarks the page on screen, or removes its bookmark.
    func toggleBookmark() { toggleBookmark(page: currentPageIndex) }

    func toggleBookmark(page index: Int) {
        guard let entry, (0..<pageCount).contains(index) else { return }
        let wasBookmarked = bookmarks.contains(index)
        var pages = Set(entry.bookmarkedPages)
        if wasBookmarked { pages.remove(index) } else { pages.insert(index) }
        entry.bookmarkedPages = pages.sorted()
        store?.save()
        bookmarks = entry.bookmarkedPages
        registerUndo(wasBookmarked ? "Remove Bookmark" : "Bookmark Page") { $0.toggleBookmark(page: index) }
    }

    func goToBookmark(_ index: Int) {
        goToPage(number: index + 1)
    }

    // MARK: Printing

    /// Prints the PDF, with or without Sheaf's highlights.
    func printPDF(includingHighlights: Bool) {
        let printed = documentForPrinting(includingHighlights: includingHighlights)
        guard let operation = printed.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        operation.jobTitle = title
        if let window = pdfView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// A copy of the PDF to print, so the one on screen is never changed.
    /// Highlights are marked to print, or left out.
    func documentForPrinting(includingHighlights: Bool) -> PDFDocument {
        guard let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data),
              !copy.isLocked
        else { return document }
        for index in 0..<copy.pageCount {
            guard let page = copy.page(at: index) else { continue }
            for annotation in page.annotations where PDFHighlights.id(of: annotation) != nil {
                if includingHighlights {
                    annotation.shouldPrint = true
                } else {
                    page.removeAnnotation(annotation)
                }
            }
        }
        return copy
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
            explainIfScanned()
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
            let index = document.index(for: page)
            let record = store.addHighlight(
                to: entry, pageIndex: index, kind: kind, text: text, rects: rects, pageLabel: storedPageLabel(at: index)
            )
            PDFHighlights.add(record, to: document)
            created.append(HighlightSnapshot(record))
        }
        guard let first = created.first else { return false }
        pdfView.clearSelection()
        refreshHighlights()
        // The one just made is the one the note shortcut and Copy as Quote use.
        selectedHighlightID = first.id
        scheduleSave()
        registerUndo("Highlight") { $0.removeHighlights(created, actionName: "Highlight") }
        return true
    }

    /// Highlights a box on a page: an area of a scanned page, or whatever
    /// was boxed with Option-drag. On a page without text, the words in the
    /// box are read off the picture afterwards; the returned task finishes
    /// then. Until (or unless) words are found, the text is "Image area".
    @discardableResult
    func highlightBox(_ rect: CGRect, onPage index: Int, as kind: HighlightKind) -> Task<Void, Never>? {
        guard let entry, let store, let page = document.page(at: index) else { return nil }
        let box = rect.intersection(page.bounds(for: .cropBox))
        guard !box.isNull, box.width > 0.5, box.height > 0.5 else { return nil }

        // A page with real text already knows the words in the box.
        let hasText = scannedPages.pageHasText(page, at: index)
        let selected = hasText ? page.selection(for: box)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        let text = selected.isEmpty ? Self.imageAreaText : selected.components(separatedBy: .newlines).joined(separator: " ")
        let record = store.addHighlight(
            to: entry, pageIndex: index, kind: kind, text: text, rects: [box], pageLabel: storedPageLabel(at: index)
        )
        PDFHighlights.add(record, to: document)
        pdfView.clearSelection()
        refreshHighlights()
        selectedHighlightID = record.id
        scheduleSave()
        // Undo takes the highlight as it is by then, with the words read from the box.
        let id = record.id
        registerUndo("Highlight") { model in
            if let record = model.highlight(id: id) {
                model.removeHighlights([HighlightSnapshot(record)], actionName: "Highlight")
            }
        }
        guard selected.isEmpty else { return nil }

        let reading = Task { [weak self] in
            guard let self else { return }
            defer { boxReadings[id] = nil }
            // From the background copy, without highlights in the way; a PDF
            // with a password only has the copy on screen.
            let image: PageImage?
            if let copy = await renderer.imageForReading(page: index, region: box) {
                image = copy
            } else {
                image = Task.isCancelled ? nil : PageImage.forReading(page, region: box)
            }
            guard let image else { return }
            let words = await TextRecognizer.lines(in: image).map(\.text).joined(separator: " ")
            // Closed meanwhile: the highlight keeps "Image area".
            guard !Task.isCancelled, !words.isEmpty, let record = highlight(id: id) else { return }
            record.text = words
            store.save()
            refreshHighlights()
        }
        boxReadings[id] = reading
        return reading
    }

    /// Stops reading scanned pages and boxes (the PDF was closed).
    func stopBackgroundWork() {
        scannedPages.cancel()
        for reading in boxReadings.values { reading.cancel() }
        boxReadings = [:]
    }

    /// Shows a note over the page for a few seconds.
    func showPageNotice(_ text: String) {
        pageNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.pageNotice = nil
        }
    }

    func dismissPageNotice() {
        noticeTask?.cancel()
        pageNotice = nil
    }

    /// With a highlighter picked on a scanned page, says why selecting text
    /// won't work there and what to do instead.
    private func explainIfScanned() {
        guard activePen != nil, let page = pdfView.currentPage,
              !scannedPages.pageHasText(page, at: document.index(for: page))
        else { return }
        showPageNotice(Self.scannedPageNotice)
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
            store.restoreHighlight(snapshot, to: entry, pageLabel: storedPageLabel(at: snapshot.pageIndex))
            PDFHighlights.add(snapshot, to: document)
        }
        refreshHighlights()
        scheduleSave()
        registerUndo(actionName) { $0.removeHighlights(snapshots, actionName: actionName) }
    }

    func registerUndo(_ actionName: String, _ action: @escaping (ReaderModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { action($0) }
        undoManager.setActionName(actionName)
    }

    func go(to record: HighlightRecord) {
        guard let page = document.page(at: record.pageIndex) else { return }
        select(record)
        rememberPlace()
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

    /// The summary, highlights grouped by meaning and page notes, as
    /// Markdown. Highlights are cited the way Copy as Quote cites them.
    func markdownExport() -> String {
        var lines = ["# \(title)", ""]
        let summary = entry?.summary ?? ""
        if !summary.isEmpty {
            lines += ["## My summary", "", summary, ""]
        }
        for kind in HighlightKind.allCases {
            let items = highlights.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            lines.append("## \(kind.name)")
            lines.append("")
            for item in items {
                lines.append("- " + Citation.quote(item.text, title: title, page: pageLabel(at: item.pageIndex)))
                if !item.note.isEmpty {
                    lines.append("  - " + Self.markdownContinued(item.note, indent: "    "))
                }
            }
            lines.append("")
        }
        if !pageNotes.isEmpty {
            lines.append("## Page notes")
            lines.append("")
            for note in pageNotes {
                let source = Citation.source(title: title, page: pageLabel(at: note.pageIndex))
                lines.append("- " + Self.markdownContinued(note.text, indent: "  ") + " (\(source))")
            }
            lines.append("")
        }
        if highlights.isEmpty && pageNotes.isEmpty && summary.isEmpty {
            lines.append("No highlights yet.")
        }
        return lines.joined(separator: "\n")
    }

    /// Whether there's anything to export: highlights, page notes or a summary.
    var hasAnythingToExport: Bool {
        !highlights.isEmpty || !pageNotes.isEmpty || !(entry?.summary.isEmpty ?? true)
    }

    /// Text over several lines, indented so Markdown keeps it in its list item.
    private static func markdownContinued(_ text: String, indent: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: "\n" + indent)
    }

    /// Reads the page notes from the library again, after a change.
    func refreshPageNotes() {
        pageNotes = (entry?.pageNotes ?? []).sorted { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
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
            explainIfScanned()
        }
        return true
    }

    // MARK: Saving into the PDF

    /// Pauses before each new try after a save failed. A new change, leaving
    /// the PDF, quitting or opening the PDF again also tries again.
    @ObservationIgnored var saveRetryDelays: [Duration] = [.seconds(5), .seconds(20), .seconds(60)]
    @ObservationIgnored private var failedSaveCount = 0
    @ObservationIgnored private var cachedSaveDelay: Duration?

    /// How long to wait after the last change before writing the file.
    /// Every save rewrites the whole file, so big files save less often
    /// (they're always saved when you leave the PDF and when Sheaf quits).
    nonisolated static func saveDelay(forFileSize bytes: Int) -> Duration {
        let small = 10_000_000, large = 50_000_000
        guard bytes > small else { return .milliseconds(1500) }
        guard bytes < large else { return .seconds(20) }
        let fraction = Double(bytes - small) / Double(large - small)
        return .milliseconds(Int(1500 + fraction * 18_500))
    }

    private var saveDelay: Duration {
        if let cachedSaveDelay { return cachedSaveDelay }
        let size = fileURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        let delay = Self.saveDelay(forFileSize: size)
        cachedSaveDelay = delay
        return delay
    }

    /// Writes highlights into the file shortly after the last change, so a
    /// burst of highlighting causes one save.
    private func scheduleSave() {
        hasUnsavedChanges = true
        failedSaveCount = 0
        saveLater(after: saveDelay)
    }

    private func saveLater(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
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
        guard hasUnsavedChanges, fileURL != nil, fileWriteBlock == nil else { return }
        guard let url = currentFileURL() else {
            didFailToSave(fileName: fileURL?.lastPathComponent ?? title)
            return
        }
        hasUnsavedChanges = false
        let snapshots = highlights.map(HighlightSnapshot.init)
        // Deleted highlights to take out of the file, and only those: any
        // other Sheaf highlight in it stays.
        let removed = Set(entry?.removedHighlightIDs ?? []).subtracting(snapshots.map(\.id))
        let archive = entry.flatMap { entry in
            store?.originalsFolder.map { OriginalPDFArchive(folder: $0, pdfID: entry.id) }
        }
        let previous = saveChain
        let task = Task { [weak self, entry, store] in
            await previous?.value
            let outcome = await Task.detached(priority: .utility) {
                PDFHighlightWriter.write(snapshots, removing: removed, to: url, keepingOriginalIn: archive)
            }.value
            // Recorded even if the PDF was closed meanwhile.
            if outcome == .saved, let entry, let store {
                store.didWriteHighlights(of: entry, to: url, removed: removed, isUpToDate: !(self?.hasUnsavedChanges ?? false))
            }
            self?.finishSave(outcome, url: url)
        }
        saveChain = task
        SaveTracker.shared.track(task, fileName: url.lastPathComponent)
    }

    /// The file to save into, found again through its bookmark before each
    /// save, so a PDF that's moved or renamed while it's open still saves.
    private func currentFileURL() -> URL? {
        guard let entry, let store else { return fileURL }
        return store.resolveFile(for: entry)
    }

    private func finishSave(_ outcome: PDFHighlightWriter.Outcome, url: URL) {
        switch outcome {
        case .saved:
            saveError = nil
            failedSaveCount = 0
        case .signed:
            fileWriteBlock = .signed
            saveError = nil
        case .passwordProtected:
            fileWriteBlock = .passwordProtected
            saveError = nil
        case .failed(let reason):
            NSLog("Sheaf: couldn\u{2019}t save highlights into \(url.path(percentEncoded: false)): \(reason)")
            didFailToSave(fileName: url.lastPathComponent)
        }
    }

    /// Keeps the changes marked unsaved and tries again after a pause, a
    /// few times. The highlights themselves are safe in the library.
    private func didFailToSave(fileName: String) {
        hasUnsavedChanges = true
        saveError = "Couldn\u{2019}t save highlights into \u{201C}\(fileName)\u{201D} yet. They\u{2019}re safe in Sheaf\u{2019}s library, and Sheaf will try again."
        guard failedSaveCount < saveRetryDelays.count else { return }
        let delay = saveRetryDelays[failedSaveCount]
        failedSaveCount += 1
        saveLater(after: delay)
    }

    // MARK: Search

    /// Starts a new search for `searchQuery`, replacing any search in progress.
    /// PDFKit searches in the background and its matches are listed a batch
    /// at a time, so long documents stay responsive. Matches in text read off
    /// scanned pages join them in document order.
    func search() {
        let query = normalizedQuery
        guard query != activeQuery else { return }

        document.cancelFindString()
        activeQuery = query
        searchResults = []
        textMatches = []
        pendingMatches = []
        recognizedMatches = [:]
        seenMatches = []
        snippets = [:]
        searchedThroughPage = -1
        selectedResultID = nil
        hasMoreResults = false
        pdfView.highlightedSelections = nil
        markRecognizedMatches()

        guard !query.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        for page in scannedPages.recognized.values {
            addRecognizedMatches(on: page)
        }
        lastResultsUpdate = .now
        document.beginFindString(query, withOptions: [.caseInsensitive])
    }

    func closeSearch() {
        searchQuery = ""
        search()
        isSearchBarVisible = false
    }

    func selectResult(id: SearchResult.ID) {
        guard searchResults.indices.contains(id) else { return }
        // Back returns to where the search started, not to each match.
        if selectedResultID == nil { rememberPlace() } else { progress.jumpStarting() }
        let result = searchResults[id]
        selectedResultID = id
        switch result.match {
        case .text(let selection):
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        case .recognized(let rect, _):
            pdfView.clearSelection()
            if let page = document.page(at: result.pageIndex) {
                pdfView.go(to: rect.insetBy(dx: 0, dy: -40), on: page)
            }
        }
        markRecognizedMatches()
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

    /// The line of text around a match, with the match in bold. Made when
    /// the match's row first shows, since finding the line takes a moment.
    func snippet(for result: SearchResult) -> AttributedString {
        if let made = snippets[result.key] { return made }
        let text: String
        switch result.match {
        case .text(let selection): text = Self.line(around: selection)
        case .recognized(_, let line): text = line
        }
        var snippet = AttributedString(text)
        if let range = snippet.range(of: activeQuery, options: .caseInsensitive) {
            snippet[range].inlinePresentationIntent = .stronglyEmphasized
        }
        snippets[result.key] = snippet
        return snippet
    }

    /// Text read off a scanned page arrived: its matches join the results.
    func recognizedPageArrived(_ page: RecognizedPage) {
        guard !activeQuery.isEmpty, addRecognizedMatches(on: page) else { return }
        // While PDFKit is still searching, they're listed with its next batch.
        if !isSearching { showSearchResults() }
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
        let key = MatchKey(pageIndex: pageIndex, bounds: selection.bounds(for: page))
        guard seenMatches.insert(key).inserted else { return }

        selection.color = .findHighlightColor
        pendingMatches.append(FoundMatch(
            key: key, pageIndex: pageIndex, pageLabel: pageLabel(at: pageIndex), match: .text(selection)
        ))
    }

    /// PDFKit finished searching a page. New matches are listed, but no more
    /// than a few times a second: each update redraws the list and the page.
    private func didSearchPage(_ index: Int?) {
        guard !activeQuery.isEmpty else { return }
        if let index { searchedThroughPage = max(searchedThroughPage, index) }
        let hasNews = !pendingMatches.isEmpty || index.map { recognizedMatches[$0] != nil } ?? false
        guard hasNews, searchResults.isEmpty || ContinuousClock.now - lastResultsUpdate > .milliseconds(250) else { return }
        showSearchResults()
    }

    private func didFinishSearching() {
        isSearching = document.isFinding
        guard !isSearching, !activeQuery.isEmpty else { return }
        searchedThroughPage = pageCount
        showSearchResults()
    }

    /// Finds the query in a scanned page's text. Returns whether it's there.
    @discardableResult
    private func addRecognizedMatches(on page: RecognizedPage) -> Bool {
        let label = pageLabel(at: page.index)
        let found = page.matches(of: activeQuery).map { match in
            FoundMatch(
                key: MatchKey(pageIndex: page.index, bounds: match.rect), pageIndex: page.index,
                pageLabel: label, match: .recognized(match.rect, line: match.line)
            )
        }
        recognizedMatches[page.index] = found.isEmpty ? nil : found
        return !found.isEmpty
    }

    /// Lists the matches found so far in document order, up to the limit.
    private func showSearchResults() {
        textMatches += pendingMatches
        pendingMatches = []
        lastResultsUpdate = .now
        let selectedKey = selectedResultID.flatMap { searchResults.indices.contains($0) ? searchResults[$0].key : nil }

        // Matches on scanned pages slot in between PDFKit's, by page, once
        // PDFKit has searched that far.
        let scanned = recognizedMatches.keys
            .filter { $0 <= searchedThroughPage }
            .sorted()
            .flatMap { recognizedMatches[$0] ?? [] }
        var merged: [FoundMatch] = []
        merged.reserveCapacity(min(textMatches.count + scanned.count, Self.searchResultLimit + 1))
        var nextText = 0, nextScanned = 0
        while merged.count <= Self.searchResultLimit, nextText < textMatches.count || nextScanned < scanned.count {
            if nextScanned == scanned.count
                || (nextText < textMatches.count && textMatches[nextText].pageIndex <= scanned[nextScanned].pageIndex) {
                merged.append(textMatches[nextText])
                nextText += 1
            } else {
                merged.append(scanned[nextScanned])
                nextScanned += 1
            }
        }
        if merged.count > Self.searchResultLimit {
            merged.removeLast(merged.count - Self.searchResultLimit)
            hasMoreResults = true
            if isSearching {
                document.cancelFindString()
                isSearching = false
            }
        }

        searchResults = merged.enumerated().map { position, found in
            SearchResult(id: position, key: found.key, pageIndex: found.pageIndex, pageLabel: found.pageLabel, match: found.match)
        }
        selectedResultID = selectedKey.flatMap { key in searchResults.firstIndex { $0.key == key } }
        let selections = searchResults.compactMap(\.selection)
        pdfView.highlightedSelections = selections.isEmpty ? nil : selections
        markRecognizedMatches()
    }

    /// Marks the listed matches on scanned pages, which PDFKit can't highlight.
    private func markRecognizedMatches() {
        var marks: [Int: [CGRect]] = [:]
        for result in searchResults {
            if case .recognized(let rect, _) = result.match {
                marks[result.pageIndex, default: []].append(rect)
            }
        }
        var selected: (page: Int, rect: CGRect)?
        if let id = selectedResultID, searchResults.indices.contains(id), case .recognized(let rect, _) = searchResults[id].match {
            selected = (page: searchResults[id].pageIndex, rect: rect)
        }
        pdfView.recognizedMatches.show(marks, selected: selected)
    }

    /// The line of text around a match, joined into one line.
    private static func line(around selection: PDFSelection) -> String {
        guard let line = selection.copy() as? PDFSelection else { return selection.string ?? "" }
        line.extendForLineBoundaries()
        return (line.string ?? "")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Notifications

    private func pageDidChange() {
        guard let page = pdfView.currentPage else { return }
        currentPageIndex = document.index(for: page)
        // Don't overwrite the saved page with page 1 while the tab is still opening.
        guard hasRestoredPosition, let entry else { return }
        entry.recordPosition(currentPageIndex)
        // A page counts as read when she reads her way to it, or once it
        // has been on screen a while; not when she jumps to it.
        let shown = visiblePageIndices.last ?? currentPageIndex
        guard shown != progress.lastPage else { return }
        if progress.arrive(at: shown, furthestRead: entry.furthestPageIndex) {
            entry.recordRead(shown)
        }
        countAsReadLater(shown)
    }

    /// Where reading starts when the PDF opens: the page it opened at.
    private func startTrackingProgress() {
        if let page = pdfView.currentPage { currentPageIndex = document.index(for: page) }
        let shown = visiblePageIndices.last ?? currentPageIndex
        progress.start(at: shown)
        countAsReadLater(shown)
    }

    /// Counts the page as read if it's still on screen after `readingDwell`.
    private func countAsReadLater(_ page: Int) {
        dwellTask?.cancel()
        guard let entry, page > entry.furthestPageIndex else { return }
        let delay = readingDwell
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, (visiblePageIndices.last ?? currentPageIndex) == page else { return }
            entry.recordRead(page)
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
            center.addObserver(forName: .PDFDocumentDidEndPageFind, object: document, queue: .main) { [weak self] notification in
                let page = (notification.userInfo?["PDFDocumentPageIndex"] as? NSNumber)?.intValue
                MainActor.assumeIsolated { self?.didSearchPage(page) }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didFinishSearching() }
            },
            center.addObserver(forName: .sheafFlushSaves, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingSave() }
            },
        ]
    }
}

/// One match in the search results list.
struct SearchResult: Identifiable {
    enum Match {
        /// Text PDFKit found.
        case text(PDFSelection)
        /// Words read off a scanned page: where they are, in page
        /// coordinates, and the line they're in.
        case recognized(CGRect, line: String)
    }

    /// Position in the results list, which is also document order.
    let id: Int
    let key: MatchKey
    let pageIndex: Int
    let pageLabel: String
    let match: Match

    /// The text PDFKit found, for matches in real text.
    var selection: PDFSelection? {
        if case .text(let selection) = match { return selection }
        return nil
    }
}

/// A match found but not yet listed.
private struct FoundMatch {
    let key: MatchKey
    let pageIndex: Int
    let pageLabel: String
    let match: SearchResult.Match
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
