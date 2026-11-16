import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What the library is showing, chosen in the sidebar.
enum LibraryScope: Hashable {
    case all
    case starred
    case collection(UUID)
}

/// The library window: every PDF opened in Sheaf, with collections,
/// reading progress and (from stage 3) highlights.
struct LibraryWindow: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.openDocument) private var openDocument
    @Query(sort: \LibraryEntry.lastOpenedAt, order: .reverse) private var items: [LibraryEntry]
    @Query(sort: \PDFCollection.createdAt) private var collections: [PDFCollection]

    @State private var scope = LibraryScope.all
    @State private var status: ReadingStatus?
    @State private var searchText = ""
    @State private var selection = Set<LibraryEntry.ID>()
    @State private var sortOrder = [KeyPathComparator(\LibraryEntry.lastOpenedAt, order: .reverse)]
    @State private var isImporting = false
    @State private var showsInspector = true
    @State private var missingItem: LibraryEntry?
    @State private var isDropTargeted = false
    @State private var searchFocus = LibrarySearchFocus()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(scope: $scope, items: items, collections: collections)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            content
                .inspector(isPresented: $showsInspector) {
                    HighlightsGuidePanel()
                        .inspectorColumnWidth(min: 250, ideal: 290, max: 360)
                }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search library")
        .searchFocused($isSearchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open PDF", systemImage: "plus") { isImporting = true }
                    .help("Open a PDF and add it to the library")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(showsInspector ? "Hide Highlights Panel" : "Show Highlights Panel", systemImage: "sidebar.right") {
                    showsInspector.toggle()
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { library.keepAccess(to: url) }
            library.add(urls: urls)
            openFiles(urls)
        }
        .alert(
            "Can't Find “\(missingItem?.title ?? "")”",
            isPresented: Binding(get: { missingItem != nil }, set: { if !$0 { missingItem = nil } }),
            presenting: missingItem
        ) { item in
            Button("Remove from Library", role: .destructive) { library.remove([item]) }
            Button("Keep", role: .cancel) {}
        } message: { item in
            Text("It was last at \(item.lastKnownPath). It may have been deleted, or moved to a drive that isn't connected.")
        }
        .focusedSceneValue(searchFocus)
        .onChange(of: searchFocus.request) { isSearchFocused = true }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if items.isEmpty {
                emptyLibrary
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .background(Theme.background)
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) ?? false }
            library.add(urls: pdfs)
            return !pdfs.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(scopeTitle)
                    .font(Theme.display(30))
                    .tracking(-0.8)
                    .foregroundStyle(Theme.ink)
                Text(rows.count == 1 ? "1 PDF" : "\(rows.count) PDFs")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkMuted)
            }
            HStack(spacing: 6) {
                FilterChip(title: "All", isSelected: status == nil) { status = nil }
                ForEach(ReadingStatus.allCases) { option in
                    FilterChip(title: option.rawValue, isSelected: status == option) { status = option }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.title) { item in
                TitleCell(item: item)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Collection", value: \.collectionName) { item in
                CollectionCell(collection: item.collection)
            }
            .width(min: 110, ideal: 160)

            TableColumn("Highlights") { _ in
                Text("—").foregroundStyle(Theme.inkMuted)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Read", value: \.progress) { item in
                Text(item.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(item.readingStatus == .unread ? Theme.inkMuted : Theme.inkSecondary)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Opened", value: \.lastOpenedAt) { item in
                Text(item.lastOpenedAt, format: .relative(presentation: .named))
                    .foregroundStyle(Theme.inkMuted)
            }
            .width(min: 90, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: LibraryEntry.ID.self) { ids in
            itemMenu(for: selectedItems(ids))
        } primaryAction: { ids in
            open(selectedItems(ids))
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "doc.on.doc")
        } description: {
            Text("Open a PDF or drag one here. Every PDF you open in Sheaf is added automatically, and stays where it is on your Mac.")
        } actions: {
            Button("Open PDF…") { isImporting = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.onAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func itemMenu(for selected: [LibraryEntry]) -> some View {
        if !selected.isEmpty {
            Button("Open") { open(selected) }
            Button("Show in Finder") {
                let urls = selected.compactMap { library.resolveFile(for: $0) }
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Divider()
            let allStarred = selected.allSatisfy(\.isStarred)
            Button(allStarred ? "Unstar" : "Star") { library.setStarred(!allStarred, for: selected) }
            Menu("Add to Collection") {
                ForEach(collections) { collection in
                    Button(collection.name) { library.move(selected, to: collection) }
                }
                if !collections.isEmpty { Divider() }
                Button("New Collection") {
                    let collection = library.createCollection(named: "New Collection")
                    library.move(selected, to: collection)
                }
            }
            if selected.contains(where: { $0.collection != nil }) {
                Button("Remove from Collection") { library.move(selected, to: nil) }
            }
            Divider()
            Button("Remove from Library", role: .destructive) {
                selection.subtract(selected.map(\.id))
                library.remove(selected)
            }
        }
    }

    // MARK: Data

    private var rows: [LibraryEntry] {
        items
            .filter { item in
                switch scope {
                case .all: true
                case .starred: item.isStarred
                case .collection(let id): item.collection?.id == id
                }
            }
            .filter { status == nil || $0.readingStatus == status }
            .filter { searchText.isEmpty || $0.title.localizedStandardContains(searchText) }
            .sorted(using: sortOrder)
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "Library"
        case .starred: "Starred"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "Library"
        }
    }

    private func selectedItems(_ ids: Set<LibraryEntry.ID>) -> [LibraryEntry] {
        rows.filter { ids.contains($0.id) }
    }

    private func open(_ selected: [LibraryEntry]) {
        for item in selected {
            guard let url = library.resolveFile(for: item) else {
                missingItem = item
                continue
            }
            openFiles([url])
        }
    }

    private func openFiles(_ urls: [URL]) {
        for url in urls {
            Task { try? await openDocument(at: url) }
        }
    }
}

extension LibraryEntry {
    /// For sorting the Collection column; PDFs without one sort last.
    var collectionName: String { collection?.name ?? "\u{10FFFF}" }
}

/// Lets Edit > Find focus the library's search field.
@Observable
final class LibrarySearchFocus {
    var request = 0
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Environment(LibraryStore.self) private var library
    @Binding var scope: LibraryScope
    let items: [LibraryEntry]
    let collections: [PDFCollection]

    @State private var renaming: PDFCollection?
    @State private var nameDraft = ""

    var body: some View {
        List(selection: Binding(get: { scope }, set: { if let new = $0 { scope = new } })) {
            Section {
                Label("Library", systemImage: "doc.text")
                    .badge(items.count)
                    .tag(LibraryScope.all)
                Label("Starred", systemImage: "star")
                    .badge(items.filter(\.isStarred).count)
                    .tag(LibraryScope.starred)
            }

            Section("Collections") {
                ForEach(collections) { collection in
                    Label {
                        Text(collection.name)
                    } icon: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.collectionColor(collection.colorIndex))
                            .frame(width: 12, height: 12)
                    }
                    .badge(collection.items.count)
                    .tag(LibraryScope.collection(collection.id))
                    .contextMenu {
                        Button("Rename…") { startRenaming(collection) }
                        Button("Delete Collection", role: .destructive) {
                            if scope == .collection(collection.id) { scope = .all }
                            library.delete(collection)
                        }
                    }
                }
                Button {
                    let collection = library.createCollection(named: "New Collection")
                    startRenaming(collection)
                } label: {
                    Label("New Collection", systemImage: "plus")
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
            }

            Section("Highlight colors") {
                ForEach(HighlightKind.allCases) { kind in
                    HStack(spacing: 10) {
                        Capsule().fill(kind.swatch).frame(width: 22, height: 10)
                        Text(kind.name).foregroundStyle(Theme.inkSecondary)
                        Spacer()
                        Text(String(kind.rawValue))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.inkMuted)
                            .help("Press \(kind.rawValue) while reading to pick this highlighter")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            HStack {
                Wordmark()
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let renaming { library.rename(renaming, to: nameDraft) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func startRenaming(_ collection: PDFCollection) {
        nameDraft = collection.name
        renaming = collection
    }
}

// MARK: - Cells and pieces

private struct TitleCell: View {
    let item: LibraryEntry

    var body: some View {
        HStack(spacing: 12) {
            Cover(data: item.cover)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if item.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.inkMuted)
                            .accessibilityLabel("Starred")
                    }
                }
                Text(item.pageCount == 1 ? "1 page" : "\(item.pageCount) pages")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct Cover: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.white)
            }
        }
        .frame(width: 26, height: 34)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.control, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private struct CollectionCell: View {
    let collection: PDFCollection?

    var body: some View {
        if let collection {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.collectionColor(collection.colorIndex))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(collection.name)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
        } else {
            Text("—").foregroundStyle(Theme.inkMuted)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 13)
                .frame(height: 28)
                .foregroundStyle(isSelected ? Theme.onAccent : Theme.inkSecondary)
                .background(isSelected ? Theme.accent : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.control, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The right-hand panel. Shows recent highlights once highlighting exists;
/// until then it explains what the four colors mean.
private struct HighlightsGuidePanel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Recent highlights")
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.ink)
                Text("Highlights you make in any PDF will appear here. Each color means something:")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(HighlightKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.name.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.4)
                        Text(kind.purpose)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color(nsColor: .black))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(nsColor: kind.pageColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(18)
        }
        .background(Theme.background)
    }
}
