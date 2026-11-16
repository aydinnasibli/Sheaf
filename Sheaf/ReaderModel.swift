import AppKit
import Observation
import PDFKit

/// The state of one document window: the PDF, the PDFKit view that shows it,
/// the current page and search. The toolbar, sidebar and menus all call into
/// this, so they stay in sync.
@Observable
final class ReaderModel {
    enum SidebarMode: Hashable {
        case pages
        case contents
    }

    let document: PDFDocument
    /// Shared by the page area and the thumbnail sidebar, so both follow the
    /// same scroll position.
    @ObservationIgnored let pdfView = PDFView()
    let outline: [OutlineItem]

    private(set) var currentPageIndex = 0
    var pageCount: Int { document.pageCount }

    var sidebarMode = SidebarMode.pages
    var isGoToPagePresented = false
    /// Incremented by Edit > Find; the window focuses its search field in response.
    var searchFocusRequest = 0

    // MARK: Search state

    var searchQuery = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    private(set) var selectedResultID: SearchResult.ID?

    var isShowingSearchResults: Bool { !normalizedQuery.isEmpty }

    // MARK: Private

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let positionStore: ReadingPositionStore
    @ObservationIgnored private var hasRestoredPosition = false
    @ObservationIgnored private var activeQuery = ""
    @ObservationIgnored private var seenMatches = Set<MatchKey>()
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(document: PDFDocument, fileURL: URL?, positionStore: ReadingPositionStore = .shared) {
        self.document = document
        self.fileURL = fileURL
        self.positionStore = positionStore
        self.outline = OutlineItem.items(under: document.outlineRoot)

        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.document = document

        observeNotifications()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Call once the window is on screen. Jumps to the page the reader left off on.
    func restoreReadingPosition() {
        guard !hasRestoredPosition else { return }
        hasRestoredPosition = true
        guard let fileURL,
              let index = positionStore.pageIndex(for: fileURL),
              index > 0, index < pageCount,
              let page = document.page(at: index)
        else { return }
        pdfView.layoutDocumentView()
        pdfView.go(to: page)
    }

    /// Call when the window closes.
    func close() {
        document.cancelFindString()
    }

    // MARK: Pages

    var canGoToPreviousPage: Bool { currentPageIndex > 0 }
    var canGoToNextPage: Bool { currentPageIndex < pageCount - 1 }

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

    // MARK: Zoom

    func zoomIn() { pdfView.zoomIn(nil) }
    func zoomOut() { pdfView.zoomOut(nil) }

    func zoomToActualSize() {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }

    func zoomToFit() {
        pdfView.autoScales = true
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

    private func refreshHighlights() {
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
        // Don't overwrite the saved page with page 1 while the window is still opening.
        if hasRestoredPosition, let fileURL {
            positionStore.save(pageIndex: currentPageIndex, for: fileURL)
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        // All observers run on the main queue, so they can safely touch UI state.
        observers = [
            center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
                nonisolated(unsafe) let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                MainActor.assumeIsolated {
                    if let selection { self?.didFind(selection) }
                }
            },
            center.addObserver(forName: .PDFDocumentDidEndPageFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshHighlights() }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSearching = self.document.isFinding
                    self.refreshHighlights()
                }
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

/// One entry in the PDF's table of contents.
struct OutlineItem: Identifiable {
    let id: ObjectIdentifier
    let title: String
    let destination: PDFDestination?
    /// `nil` for entries with no sub-entries, as `List(children:)` expects.
    let children: [OutlineItem]?
    /// Keeps the PDFKit object alive so `id` stays unique.
    private let outline: PDFOutline

    init(_ outline: PDFOutline) {
        self.outline = outline
        id = ObjectIdentifier(outline)
        title = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        let children = Self.items(under: outline)
        self.children = children.isEmpty ? nil : children
    }

    static func items(under parent: PDFOutline?) -> [OutlineItem] {
        guard let parent else { return [] }
        return (0..<parent.numberOfChildren).compactMap { parent.child(at: $0) }.map(OutlineItem.init)
    }
}

private struct MatchKey: Hashable {
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
