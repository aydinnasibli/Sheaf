import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySidebar: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Workspace.self) private var workspace
    @Binding var scope: LibraryScope
    /// The colors the Highlights and Notes pages show; empty means all.
    @Binding var highlightKinds: Set<HighlightKind>
    let entries: [LibraryEntry]
    let collections: [PDFCollection]
    let highlights: [HighlightRecord]

    @Environment(\.undoManager) private var undoManager
    @State private var renaming: PDFCollection?
    @State private var nameDraft = ""
    /// The collection she asked to delete, until she confirms: its ID and
    /// what the confirmation says, kept apart from the collection, which is
    /// gone while the alert closes.
    @State private var deleting: (id: UUID, summary: CollectionDeletionSummary)?
    /// The row PDFs are being dragged over.
    @State private var dropTarget: LibraryScope?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 2) {
                    NavRow(title: "Library", count: entries.count, isSelected: scope == .all) {
                        Image(systemName: "doc.text")
                    } action: { scope = .all }
                    NavRow(title: "Highlights", count: highlights.count, isSelected: scope == .highlights) {
                        Image(systemName: "highlighter")
                    } action: {
                        scope = .highlights
                        highlightKinds = []
                    }
                    // Highlights with a note, page notes and summaries.
                    NavRow(title: "Notes", count: entries.reduce(0) { $0 + $1.notesCount }, isSelected: scope == .notes) {
                        Image(systemName: "text.bubble")
                    } action: {
                        scope = .notes
                        highlightKinds = []
                    }
                    NavRow(title: "Review", count: nil, isSelected: scope == .review) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                    } action: { scope = .review }
                    .help("Flashcards from your highlights (\u{21E7}\u{2318}R)")
                    NavRow(title: "Starred", count: entries.count(where: \.isStarred), isSelected: scope == .starred) {
                        Image(systemName: "star")
                    } action: { scope = .starred }
                    .dropTarget(.starred, current: $dropTarget) { files in
                        Task { _ = await library.addFiles(files, starred: true) }
                    }
                }

                if !workspace.documents.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionLabel(title: "Open now")
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                        ForEach(workspace.documents) { document in
                            OpenDocumentRow(title: document.title) {
                                workspace.select(document.id)
                            } close: {
                                workspace.close(document.id)
                            }
                        }
                    }
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
                        // PDFs dragged from the list or from Finder join the
                        // collection (new ones are added to the library too).
                        .dropTarget(.collection(collection.id), current: $dropTarget) { files in
                            Task { _ = await library.addFiles(files, to: collection) }
                        }
                        .contextMenu {
                            Button("Rename\u{2026}") { startRenaming(collection) }
                            Button("Delete Collection\u{2026}", role: .destructive) {
                                deleting = (collection.id, CollectionDeletionSummary(collection))
                            }
                        }
                    }
                    // Asks for the name first, as File › Add to Collection does.
                    Button {
                        workspace.requestNewCollection()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").frame(width: 16)
                            Text("New Collection")
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 32)
                    }
                    .buttonStyle(.sheaf())
                    .accessibilityLabel("New Collection")
                }

                // Each color opens the Highlights page showing only that color.
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(title: "Highlight colors")
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                    let counts = totalCounts
                    ForEach(Array(HighlightKind.allCases.enumerated()), id: \.element) { index, kind in
                        let isSelected = scope == .highlights && highlightKinds == [kind]
                        Button {
                            scope = .highlights
                            highlightKinds = [kind]
                        } label: {
                            HStack(spacing: 10) {
                                Capsule().fill(kind.swatch).frame(width: 22, height: 10)
                                Text(kind.name)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                                Spacer()
                                Text(String(counts[index]))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.inkMuted)
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(isSelected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.control : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.sheaf())
                        .help("\(kind.purpose). Press \(kind.rawValue) while reading. Click to see these highlights.")
                        .accessibilityLabel("\(kind.name) highlights")
                        .accessibilityValue(String(counts[index]))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        .alert(
            deleting?.summary.title ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { deleting in
            // ⌘Z brings it back, with its PDFs.
            Button("Delete", role: .destructive) {
                workspace.deleteCollection(deleting.id, undoManager: undoManager)
            }
            Button("Cancel", role: .cancel) {}
        } message: { deleting in
            Text(deleting.summary.message)
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

/// A PDF that's open, in the "Open now" list. Click to return to it.
struct OpenDocumentRow: View {
    let title: String
    let open: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // The row shows its own hover, so the button adds no tint of its own.
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext")
                        .frame(width: 16)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(.sheaf(.quiet, in: Rectangle()))
            .help("Return to \u{201C}\(title)\u{201D}")
            .accessibilityLabel(title)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.sheaf(cornerRadius: 5))
            .opacity(isHovered ? 1 : 0)
            .animation(Theme.hoverAnimation, value: isHovered)
            .help("Close \u{201C}\(title)\u{201D}")
            .accessibilityLabel("Close \(title)")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isHovered ? Theme.hoverTint : .clear, in: RoundedRectangle(cornerRadius: 8))
        .animation(Theme.hoverAnimation, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

struct NavRow<Icon: View>: View {
    let title: String
    /// Shown on the right; `nil` for rows that don't count anything.
    let count: Int?
    let isSelected: Bool
    @ViewBuilder var icon: Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text(String(count))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isSelected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.control : .clear, lineWidth: 1))
        }
        .buttonStyle(.sheaf())
        .accessibilityLabel(title)
        .accessibilityValue(count.map(String.init) ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    /// Lets PDFs and folders be dropped on a row of the left panel, from the
    /// library's list or from Finder. The row is outlined while they're over it.
    func dropTarget(
        _ row: LibraryScope, current: Binding<LibraryScope?>, perform: @escaping ([URL]) -> Void
    ) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { LibraryStore.isPDF($0) || LibraryStore.isFolder($0) }
            guard !files.isEmpty else { return false }
            perform(files)
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                current.wrappedValue = row
            } else if current.wrappedValue == row {
                current.wrappedValue = nil
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity(current.wrappedValue == row ? 1 : 0)
                .animation(Theme.hoverAnimation, value: current.wrappedValue == row)
                .allowsHitTesting(false)
        }
    }
}
