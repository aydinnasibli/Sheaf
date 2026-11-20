import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What the library is showing, chosen in the left panel.
enum LibraryScope: Hashable {
    case all
    case starred
    case highlights
    case notes
    /// Flashcards from highlights.
    case review
    case collection(UUID)

    /// Highlights and Notes show highlights rather than PDFs.
    var showsHighlights: Bool { self == .highlights || self == .notes }
    /// The list of PDFs, with search, filters and recent highlights.
    var showsPDFs: Bool { !showsHighlights && self != .review }
}

/// The filter chips above the list.
enum LibraryFilter: Hashable, CaseIterable {
    case all, unread, inProgress, finished, openQuestions

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .inProgress: "In progress"
        case .finished: "Finished"
        case .openQuestions: "Open questions"
        }
    }

    func matches(_ entry: LibraryEntry) -> Bool {
        switch self {
        case .all: true
        case .unread: entry.readingStatus == .unread
        case .inProgress: entry.readingStatus == .inProgress
        case .finished: entry.readingStatus == .finished
        case .openQuestions: entry.hasOpenQuestions
        }
    }
}

/// The list's sortable columns.
enum LibraryColumn {
    case title, collection, highlights, read, opened
}

/// The library window (C · Library mockup): header with search, the left
/// panel, the list of PDFs and recent highlights.
struct LibraryScreen: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Workspace.self) private var workspace
    @Query(sort: \LibraryEntry.lastOpenedAt, order: .reverse) private var entries: [LibraryEntry]
    @Query(sort: \PDFCollection.createdAt) private var collections: [PDFCollection]
    @Query(LibraryScreen.recentHighlightsQuery) private var recentHighlights: [HighlightRecord]
    @Query(sort: \HighlightRecord.createdAt, order: .reverse) private var allHighlights: [HighlightRecord]
    /// Notes on whole pages, for the Notes page.
    @Query(sort: \PageNote.createdAt, order: .reverse) private var pageNotes: [PageNote]

    @State private var filter = LibraryFilter.all
    /// The colors the Highlights and Notes pages show, like "2,4". Kept for
    /// the window, so after reading a PDF opened from the page she comes
    /// back to the same colors (along with the page's other choices).
    @SceneStorage("highlightKinds") private var highlightKindsValue = ""
    @State private var searchText = ""
    @State private var sortColumn = LibraryColumn.opened
    @State private var sortAscending = false
    @State private var isDropTargeted = false
    @State private var width: CGFloat = 1280
    /// The left panel, shown over the list in a window too narrow for it beside the list.
    @State private var showsSidebarOverlay = false
    /// Finds PDFs whose text contains the search.
    @State private var textSearch = LibraryTextSearch()
    @FocusState private var isSearchFocused: Bool

    /// The section shown, chosen in the left panel. The workspace keeps it,
    /// so the library comes back to it after reading a PDF.
    private var scope: LibraryScope { workspace.libraryScope }

    private var highlightKinds: Binding<Set<HighlightKind>> {
        Binding {
            Set(highlightKindsValue.split(separator: ",").compactMap { Int($0).flatMap(HighlightKind.init(rawValue:)) })
        } set: { kinds in
            highlightKindsValue = kinds.map(\.rawValue).sorted().map(String.init).joined(separator: ",")
        }
    }

    static var recentHighlightsQuery: FetchDescriptor<HighlightRecord> {
        var descriptor = FetchDescriptor<HighlightRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 6
        return descriptor
    }

    /// The left panel needs room beside the list; in a narrower window its
    /// button shows it over the list instead.
    private var sidebarFits: Bool { width >= 820 }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarFits {
                sidebar
                Hairline(axis: .vertical)
            }
            content
        }
        .panelOverlay(isPresented: showsSidebarOverlay && !sidebarFits, edge: .leading) {
            showsSidebarOverlay = false
        } panel: {
            sidebar
        }
        // Esc puts the left panel away when it's over the list.
        .onExitCommand(perform: showsSidebarOverlay ? { showsSidebarOverlay = false } : nil)
        // Picking a section in the panel over the list shows it; widening
        // the window puts the panel back beside the list.
        .onChange(of: scope) { showsSidebarOverlay = false }
        .onChange(of: sidebarFits) { showsSidebarOverlay = false }
        .overlay(alignment: .top) { Hairline() }
        .background(Theme.background)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("Library")
        .toolbar { header }
        .sheafHeader()
        .onChange(of: workspace.librarySearchRequest) { isSearchFocused = true }
        .onChange(of: searchText) {
            // Review has nothing to search; searching shows the library.
            if scope == .review && !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                workspace.libraryScope = .all
            }
        }
        .task(id: textSearchKey) {
            await textSearch.run(textSearchKey.query, in: scope.showsPDFs ? entries.filter { isInScope($0) && filter.matches($0) } : [])
        }
    }

    private var sidebar: some View {
        LibrarySidebar(
            scope: Bindable(workspace).libraryScope,
            highlightKinds: highlightKinds,
            entries: entries,
            collections: collections,
            highlights: allHighlights
        )
        .frame(width: 216)
    }

    /// The section picked in the left panel, and recent highlights beside the list.
    @ViewBuilder
    private var content: some View {
        if scope == .review {
            ReviewPage(highlights: allHighlights, entries: entries, collections: collections)
        } else if scope.showsHighlights {
            HighlightsPage(
                title: scope == .notes ? "Notes" : "Highlights",
                records: allHighlights.filter { scope != .notes || !$0.note.isEmpty },
                pageNotes: scope == .notes ? pageNotes : [],
                summaries: scope == .notes ? entries.filter { !$0.summary.isEmpty } : [],
                isNotesPage: scope == .notes,
                searchText: searchText,
                kinds: highlightKinds,
                entries: entries,
                collections: collections
            ) { record in
                if let entry = record.entry { WindowRouter.shared.open(entry, at: record) }
            } onOpenPDF: { entry, page in
                if let page { open(entry, atPage: page) } else { workspace.openPDFs([entry]) }
            }
        } else {
            main
        }
        if width >= 1100 && scope.showsPDFs {
            Hairline(axis: .vertical)
            RecentHighlightsPanel(records: recentHighlights) { record in
                if let entry = record.entry { WindowRouter.shared.open(entry, at: record) }
            }
            .frame(width: 300)
        }
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var header: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                if !sidebarFits {
                    SquareIconButton(
                        label: showsSidebarOverlay ? "Hide the left panel" : "Show the left panel: sections and collections",
                        systemImage: "sidebar.left",
                        isOn: showsSidebarOverlay
                    ) { showsSidebarOverlay.toggle() }
                }
                Wordmark().padding(.horizontal, 6)
            }
        }
        .plainBackground()

        ToolbarItem(placement: .principal) {
            LibrarySearchField(text: $searchText, isFocused: $isSearchFocused)
                .frame(width: min(520, max(240, width - 560)))
        }
        .plainBackground()

        ToolbarItem(placement: .primaryAction) {
            PrimaryButton(title: "Open PDF", systemImage: "plus") {
                WindowRouter.shared.showOpenPanel()
            }
            .help("Open PDFs and add them to the library (\u{2318}O)")
        }
        .plainBackground()
    }

    // MARK: Main column

    private var main: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(scopeTitle)
                    .font(Theme.display(32))
                    .tracking(-0.9)
                    .foregroundStyle(Theme.ink)
                Text(rows.count == 1 ? "1 PDF" : "\(rows.count) PDFs")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkMuted)
            }

            FlowLayout(spacing: 6) {
                ForEach(LibraryFilter.allCases, id: \.self) { option in
                    if option == .openQuestions {
                        FilterChip(title: openQuestionsTitle, dot: HighlightKind.question.vivid, isSelected: filter == option) {
                            filter = option
                        }
                        .help("PDFs with questions you haven\u{2019}t answered yet")
                    } else {
                        FilterChip(title: option.title, isSelected: filter == option) { filter = option }
                    }
                }
            }

            if entries.isEmpty {
                EmptyLibrary()
            } else if rows.isEmpty && textMatches.isEmpty {
                // Nothing yet while the PDFs' text is still being searched.
                if !textSearch.isSearching(textSearchKey.query) { noRows }
            } else if textMatches.isEmpty {
                list
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if !rows.isEmpty {
                        // Matches in titles, highlights and notes come first.
                        list.frame(maxHeight: TextMatchesSection.listHeight(rows: rows.count))
                    }
                    TextMatchesSection(matches: textMatches, entries: entries, query: textSearchKey.query) { entry, page in
                        open(entry, atPage: page)
                    }
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: $isDropTargeted) { files in
            // Dropped on a collection, PDFs join it; dropped on Starred, they're starred.
            let collection = shownCollection
            let starred = scope == .starred
            Task { _ = await library.addFiles(files, to: collection, starred: starred) }
        })
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var list: some View {
        PDFList(rows: rows, collections: collections, sortColumn: $sortColumn, sortAscending: $sortAscending)
    }

    /// Shown when the library has PDFs but none fit the search, filter or
    /// section. Says which one is hiding them, and how to see them again.
    @ViewBuilder
    private var noRows: some View {
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filter != .all {
            EmptyMessage(
                systemImage: filter == .openQuestions ? "questionmark.bubble" : "line.3.horizontal.decrease",
                title: filterEmptyTitle,
                message: filterEmptyMessage,
                actionTitle: "Show All PDFs"
            ) { filter = .all }
        } else if scope == .starred {
            EmptyMessage(
                systemImage: "star",
                title: "No starred PDFs",
                message: "Right-click a PDF and choose Star to keep it here."
            )
        } else {
            EmptyMessage(
                systemImage: "folder",
                title: "This collection is empty",
                message: "Right-click a PDF and choose Add to Collection."
            )
        }
    }

    private var filterEmptyTitle: String {
        switch filter {
        case .all: ""
        case .unread: "No unread PDFs"
        case .inProgress: "Nothing in progress"
        case .finished: "No finished PDFs"
        case .openQuestions: "No open questions"
        }
    }

    private var filterEmptyMessage: String {
        let place = scope == .all ? "your library" : "here"
        switch filter {
        case .all: return ""
        case .unread: return "You\u{2019}ve started every PDF in \(place)."
        case .inProgress: return "PDFs you\u{2019}ve started but not finished show up here."
        case .finished: return "PDFs you\u{2019}ve read to the end show up here."
        case .openQuestions: return "PDFs with questions you haven\u{2019}t answered yet show up here. Answer a question on the Highlights page or while reading."
        }
    }

    /// "Open questions · 3": the questions not answered yet in the PDFs
    /// here. Answering one brings the number down.
    private var openQuestionsTitle: String {
        let count = entries.reduce(0) { $0 + (isInScope($1) ? $1.openQuestionCount : 0) }
        return count == 0 ? LibraryFilter.openQuestions.title : "\(LibraryFilter.openQuestions.title) \u{00B7} \(count)"
    }

    // MARK: Data

    private var rows: [LibraryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let shown = entries.filter { entry in
            guard isInScope(entry), filter.matches(entry) else { return false }
            guard !query.isEmpty else { return true }
            return entry.title.localizedStandardContains(query)
                || entry.highlights.contains {
                    $0.text.localizedStandardContains(query) || $0.note.localizedStandardContains(query)
                        || ($0.isAnsweredQuestion && $0.answer.localizedStandardContains(query))
                }
        }
        let sorted = shown.sorted { a, b in
            switch sortColumn {
            case .title: a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .collection: a.collectionName.localizedStandardCompare(b.collectionName) == .orderedAscending
            case .highlights: a.highlights.count < b.highlights.count
            case .read: a.progress < b.progress
            case .opened: a.lastOpenedAt < b.lastOpenedAt
            }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private func isInScope(_ entry: LibraryEntry) -> Bool {
        switch scope {
        case .all, .highlights, .notes, .review: true
        case .starred: entry.isStarred
        case .collection(let id): entry.collection?.id == id
        }
    }

    /// The collection on screen, if the library is showing one.
    private var shownCollection: PDFCollection? {
        guard case .collection(let id) = scope else { return nil }
        return collections.first { $0.id == id }
    }

    /// Runs the search of PDFs' text again when the search, section or filter changes.
    private var textSearchKey: TextSearchKey {
        TextSearchKey(query: searchText.trimmingCharacters(in: .whitespaces), scope: scope, filter: filter)
    }

    private var textMatches: [TextIndex.Match] { textSearch.matches(for: textSearchKey.query) }

    private var scopeTitle: String {
        switch scope {
        case .all: "Library"
        case .starred: "Starred"
        case .highlights: "Highlights"
        case .notes: "Notes"
        case .review: "Review"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "Library"
        }
    }

    private func open(_ entry: LibraryEntry, atPage pageIndex: Int) {
        guard library.resolveFile(for: entry) != nil else {
            workspace.missingFileRequest = entry.id
            return
        }
        WindowRouter.shared.open(entry, atPage: pageIndex)
    }
}

struct LibrarySearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
            TextField("Search PDFs, highlights and notes", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.ink)
                .focused(isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.inkMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.sheaf(.quiet, in: Circle()))
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
            Text("\u{2318}K")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.control, lineWidth: 1))
                .accessibilityHidden(true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { isFocused.wrappedValue = true }
    }
}
