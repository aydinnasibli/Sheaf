import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What the library is showing, chosen in the left panel.
enum LibraryScope: Hashable {
    case all
    case starred
    case collection(UUID)
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

/// Lets Edit > Find and ⌘K focus the library's search field.
@Observable
final class LibrarySearchFocus {
    var request = 0
}

/// The library window (C · Library mockup): header with search, the left
/// panel, the list of PDFs and recent highlights.
struct LibraryWindow: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \LibraryEntry.lastOpenedAt, order: .reverse) private var entries: [LibraryEntry]
    @Query(sort: \PDFCollection.createdAt) private var collections: [PDFCollection]
    @Query(LibraryWindow.recentHighlightsQuery) private var recentHighlights: [HighlightRecord]

    @State private var scope = LibraryScope.all
    @State private var filter = LibraryFilter.all
    @State private var searchText = ""
    @State private var selection: LibraryEntry.ID?
    @State private var sortColumn = LibraryColumn.opened
    @State private var sortAscending = false
    @State private var missingEntry: LibraryEntry?
    @State private var isDropTargeted = false
    @State private var searchFocus = LibrarySearchFocus()
    @State private var width: CGFloat = 1280
    @FocusState private var isSearchFocused: Bool

    static var recentHighlightsQuery: FetchDescriptor<HighlightRecord> {
        var descriptor = FetchDescriptor<HighlightRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 6
        return descriptor
    }

    var body: some View {
        HStack(spacing: 0) {
            if width >= 820 {
                LibraryNav(scope: $scope, entries: entries, collections: collections)
                    .frame(width: 216)
                Hairline(axis: .vertical)
            }
            main
            if width >= 1100 {
                Hairline(axis: .vertical)
                RecentHighlightsPanel(records: recentHighlights) { record in
                    if let entry = record.entry {
                        entry.lastPageIndex = record.pageIndex
                        open([entry])
                    }
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
        .focusedSceneValue(searchFocus)
        .onChange(of: searchFocus.request) { isSearchFocused = true }
        .onAppear { WindowRouter.shared.attach(openWindow) }
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

            HStack(spacing: 6) {
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
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) ?? false }
            library.add(urls: pdfs)
            return !pdfs.isEmpty
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
            let inScope = switch scope {
            case .all: true
            case .starred: entry.isStarred
            case .collection(let id): entry.collection?.id == id
            }
            guard inScope, filter.matches(entry) else { return false }
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

    private var scopeTitle: String {
        switch scope {
        case .all: "Library"
        case .starred: "Starred"
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

extension LibraryEntry {
    /// For sorting by collection; PDFs without one sort last.
    var collectionName: String { collection?.name ?? "\u{10FFFF}" }
}

// MARK: - Header search

private struct LibrarySearchField: View {
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
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
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

// MARK: - Left panel

private struct LibraryNav: View {
    @Environment(LibraryStore.self) private var library
    @Binding var scope: LibraryScope
    let entries: [LibraryEntry]
    let collections: [PDFCollection]

    @State private var renaming: PDFCollection?
    @State private var nameDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 2) {
                    NavRow(title: "Library", count: entries.count, isSelected: scope == .all) {
                        Image(systemName: "doc.text")
                    } action: { scope = .all }
                    NavRow(title: "Starred", count: entries.count(where: \.isStarred), isSelected: scope == .starred) {
                        Image(systemName: "star")
                    } action: { scope = .starred }
                }

                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(title: "Collections")
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                    ForEach(collections) { collection in
                        NavRow(
                            title: collection.name,
                            count: collection.items.count,
                            isSelected: scope == .collection(collection.id)
                        ) {
                            Swatch(color: Theme.collectionColor(collection.colorIndex))
                        } action: {
                            scope = .collection(collection.id)
                        }
                        .contextMenu {
                            Button("Rename\u{2026}") { startRenaming(collection) }
                            Button("Delete Collection", role: .destructive) {
                                if scope == .collection(collection.id) { scope = .all }
                                library.delete(collection)
                            }
                        }
                    }
                    Button {
                        startRenaming(library.createCollection(named: "New Collection"))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").frame(width: 16)
                            Text("New Collection")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 9) {
                    SectionLabel(title: "Highlight colors")
                        .padding(.horizontal, 10)
                    let counts = totalCounts
                    ForEach(Array(HighlightKind.allCases.enumerated()), id: \.element) { index, kind in
                        HStack(spacing: 10) {
                            Capsule().fill(kind.swatch).frame(width: 22, height: 10)
                            Text(kind.name).foregroundStyle(Theme.inkSecondary)
                            Spacer()
                            Text(String(counts[index]))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .help("\(kind.purpose). Press \(kind.rawValue) while reading.")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .background(Theme.sidebar)
        .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let renaming { library.rename(renaming, to: nameDraft) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var totalCounts: [Int] {
        entries.reduce(into: Array(repeating: 0, count: HighlightKind.allCases.count)) { totals, entry in
            for (index, count) in entry.highlightCounts.enumerated() { totals[index] += count }
        }
    }

    private func startRenaming(_ collection: PDFCollection) {
        nameDraft = collection.name
        renaming = collection
    }
}

private struct NavRow<Icon: View>: View {
    let title: String
    let count: Int
    let isSelected: Bool
    @ViewBuilder var icon: Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text(String(count))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isSelected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.control : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - List

/// Column widths, as fractions of the list width (from the mockup).
private enum Columns {
    static let title: CGFloat = 0.41
    static let collection: CGFloat = 0.20
    static let highlights: CGFloat = 0.18
    static let read: CGFloat = 0.09
    static let opened: CGFloat = 0.12
}

private struct ColumnHeader: View {
    @Binding var sortColumn: LibraryColumn
    @Binding var ascending: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                header("Title", .title, width * Columns.title)
                header("Collection", .collection, width * Columns.collection)
                header("Highlights", .highlights, width * Columns.highlights)
                header("Read", .read, width * Columns.read)
                header("Opened", .opened, width * Columns.opened)
            }
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func header(_ title: String, _ column: LibraryColumn, _ width: CGFloat) -> some View {
        Button {
            if sortColumn == column {
                ascending.toggle()
            } else {
                sortColumn = column
                ascending = column == .title || column == .collection
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(sortColumn == column ? Theme.inkSecondary : Theme.inkMuted)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
    }
}

private struct LibraryRow: View {
    let entry: LibraryEntry
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    Cover(data: entry.cover)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(entry.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            if entry.isStarred {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.inkMuted)
                                    .accessibilityLabel("Starred")
                            }
                        }
                        Text(entry.pageCount == 1 ? "1 page" : "\(entry.pageCount) pages")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer(minLength: 12)
                }
                .frame(width: width * Columns.title, alignment: .leading)

                Group {
                    if let collection = entry.collection {
                        HStack(spacing: 7) {
                            Swatch(color: Theme.collectionColor(collection.colorIndex), size: 10)
                            Text(collection.name).lineLimit(1)
                        }
                    } else {
                        Text("\u{2014}").foregroundStyle(Theme.inkMuted)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: width * Columns.collection, alignment: .leading)

                HStack(spacing: 8) {
                    let counts = entry.highlightCounts
                    let total = counts.reduce(0, +)
                    HighlightMixBar(counts: counts, width: min(88, width * Columns.highlights - 36))
                    Text(total == 0 ? "\u{2014}" : String(total))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(width: width * Columns.highlights, alignment: .leading)

                Text(entry.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(entry.readingStatus == .unread ? Theme.inkMuted : Theme.inkSecondary)
                    .frame(width: width * Columns.read, alignment: .leading)

                Text(entry.lastOpenedAt, format: .relative(presentation: .named))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .frame(width: width * Columns.opened, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 58)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Theme.selectedRow : (isHovered ? Theme.selectedRow.opacity(0.5) : .clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1).padding(.horizontal, 8)
        }
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-click to open")
    }
}

private struct Cover: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white
            }
        }
        .frame(width: 24, height: 30)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.control, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private struct EmptyLibrary: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("Your library is empty")
                .font(Theme.display(22))
                .foregroundStyle(Theme.ink)
            Text("Open a PDF or drag one here. Every PDF you open in Sheaf is added automatically and stays where it is on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            PrimaryButton(title: "Open PDF\u{2026}", systemImage: "plus") {
                WindowRouter.shared.showOpenPanel()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recent highlights

private struct RecentHighlightsPanel: View {
    let records: [HighlightRecord]
    let onSelect: (HighlightRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent highlights")
                .font(Theme.display(18))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if records.isEmpty {
                        guide
                    } else {
                        ForEach(records) { record in
                            Button { onSelect(record) } label: { card(record) }
                                .buttonStyle(.plain)
                                .help("Open at page \(record.pageIndex + 1)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .background(Theme.background)
    }

    private func card(_ record: HighlightRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.kind.name.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(record.kind.chipText)
            Text(record.text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Text("\(record.entry?.title ?? "PDF") \u{00B7} p. \(record.pageIndex + 1)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(record.kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlights you make in any PDF show up here. Each color means something:")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(HighlightKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(kind.name.uppercased())  \u{00B7}  KEY \(kind.rawValue)")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(kind.chipText)
                    Text(kind.purpose)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
