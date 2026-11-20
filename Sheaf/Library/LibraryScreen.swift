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

    @State private var filter = LibraryFilter.all
    @State private var highlightKinds = Set<HighlightKind>()
    @State private var searchText = ""
    @State private var selection: LibraryEntry.ID?
    @State private var sortColumn = LibraryColumn.opened
    @State private var sortAscending = false
    @State private var missingEntry: LibraryEntry?
    @State private var isDropTargeted = false
    @State private var width: CGFloat = 1280
    /// Finds PDFs whose text contains the search.
    @State private var textSearch = LibraryTextSearch()
    @FocusState private var isSearchFocused: Bool

    /// The section shown, chosen in the left panel. The workspace keeps it,
    /// so the library comes back to it after reading a PDF.
    private var scope: LibraryScope { workspace.libraryScope }

    static var recentHighlightsQuery: FetchDescriptor<HighlightRecord> {
        var descriptor = FetchDescriptor<HighlightRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 6
        return descriptor
    }

    var body: some View {
        HStack(spacing: 0) {
            if width >= 820 {
                LibrarySidebar(
                    scope: Bindable(workspace).libraryScope,
                    highlightKinds: $highlightKinds,
                    entries: entries,
                    collections: collections,
                    highlights: allHighlights
                )
                .frame(width: 216)
                Hairline(axis: .vertical)
            }
            if scope == .review {
                ReviewPage(highlights: allHighlights, entries: entries, collections: collections)
            } else if scope.showsHighlights {
                HighlightsPage(
                    title: scope == .notes ? "Notes" : "Highlights",
                    records: allHighlights.filter { scope != .notes || !$0.note.isEmpty },
                    searchText: searchText,
                    kinds: $highlightKinds
                ) { record in
                    if let entry = record.entry { WindowRouter.shared.open(entry, at: record) }
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
        .alert(
            "Can\u{2019}t Find \u{201C}\(missingEntry?.title ?? "")\u{201D}",
            isPresented: Binding(get: { missingEntry != nil }, set: { if !$0 { missingEntry = nil } }),
            presenting: missingEntry
        ) { entry in
            Button("Remove from Library", role: .destructive) { library.remove([entry]) }
            Button("Keep", role: .cancel) {}
        } message: { entry in
            Text("It was last at \(entry.lastKnownPath). It may have been deleted, or moved to a drive that isn\u{2019}t connected.")
        }
    }

    // MARK: Header

    @ToolbarContentBuilder
    private var header: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Wordmark().padding(.horizontal, 6)
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
                    FilterChip(
                        title: option.title,
                        dot: option == .openQuestions ? HighlightKind.question.vivid : nil,
                        isSelected: filter == option
                    ) { filter = option }
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
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { LibraryStore.isPDF($0) || LibraryStore.isFolder($0) }
            guard !files.isEmpty else { return false }
            // Dropped on a collection, PDFs join it; dropped on Starred, they're starred.
            let collection = shownCollection
            let starred = scope == .starred
            Task { _ = await library.addFiles(files, to: collection, starred: starred) }
            return true
        } isTargeted: { isDropTargeted = $0 }
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
        VStack(spacing: 0) {
            ColumnHeader(sortColumn: $sortColumn, ascending: $sortAscending)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { entry in
                            LibraryRow(entry: entry, isSelected: selection == entry.id)
                                .id(entry.id)
                                .onTapGesture(count: 2) { open([entry]) }
                                .simultaneousGesture(TapGesture().onEnded { selection = entry.id })
                                .contextMenu { menu(for: entry) }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.return) {
            guard let entry = rows.first(where: { $0.id == selection }) else { return .ignored }
            open([entry])
            return .handled
        }
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
        case .openQuestions: return "PDFs with a Question highlight show up here."
        }
    }

    @ViewBuilder
    private func menu(for entry: LibraryEntry) -> some View {
        Button("Open") { open([entry]) }
        Button("Show in Finder") {
            if let url = library.resolveFile(for: entry) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Divider()
        Button(entry.isStarred ? "Unstar" : "Star") { library.setStarred(!entry.isStarred, for: [entry]) }
        Menu("Add to Collection") {
            ForEach(collections) { collection in
                Button(collection.name) { library.move([entry], to: collection) }
            }
            if !collections.isEmpty { Divider() }
            Button("New Collection") {
                library.move([entry], to: library.createCollection(named: "New Collection"))
            }
        }
        if entry.collection != nil {
            Button("Remove from Collection") { library.move([entry], to: nil) }
        }
        Divider()
        Button("Remove from Library", role: .destructive) {
            if selection == entry.id { selection = nil }
            library.remove([entry])
        }
    }

    // MARK: Data

    private var rows: [LibraryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let shown = entries.filter { entry in
            guard isInScope(entry), filter.matches(entry) else { return false }
            guard !query.isEmpty else { return true }
            return entry.title.localizedStandardContains(query)
                || entry.highlights.contains { $0.text.localizedStandardContains(query) || $0.note.localizedStandardContains(query) }
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

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let current = selection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : ids.count)
        selection = ids[min(max(current + offset, 0), ids.count - 1)]
        return .handled
    }

    private func open(_ entry: LibraryEntry, atPage pageIndex: Int) {
        guard library.resolveFile(for: entry) != nil else {
            missingEntry = entry
            return
        }
        WindowRouter.shared.open(entry, atPage: pageIndex)
    }

    private func open(_ selected: [LibraryEntry]) {
        for entry in selected {
            guard library.resolveFile(for: entry) != nil else {
                missingEntry = entry
                continue
            }
            WindowRouter.shared.open(entry)
        }
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
