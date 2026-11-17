import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct LibrarySidebar: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Workspace.self) private var workspace
    @Binding var scope: LibraryScope
    let entries: [LibraryEntry]
    let collections: [PDFCollection]
    let highlights: [HighlightRecord]

    @State private var renaming: PDFCollection?
    @State private var nameDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 2) {
                    NavRow(title: "Library", count: entries.count, isSelected: scope == .all) {
                        Image(systemName: "doc.text")
                    } action: { scope = .all }
                    NavRow(title: "Highlights", count: highlights.count, isSelected: scope == .highlights) {
                        Image(systemName: "highlighter")
                    } action: { scope = .highlights }
                    NavRow(title: "Notes", count: highlights.count { !$0.note.isEmpty }, isSelected: scope == .notes) {
                        Image(systemName: "text.bubble")
                    } action: { scope = .notes }
                    NavRow(title: "Starred", count: entries.count(where: \.isStarred), isSelected: scope == .starred) {
                        Image(systemName: "star")
                    } action: { scope = .starred }
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
                    .accessibilityLabel("New Collection")
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

/// A PDF that's open, in the "Open now" list. Click to return to it.
struct OpenDocumentRow: View {
    let title: String
    let open: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext")
                        .frame(width: 16)
                    Text(title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Return to \u{201C}\(title)\u{201D}")
            .accessibilityLabel(title)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Close \u{201C}\(title)\u{201D}")
            .accessibilityLabel("Close \(title)")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isHovered ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
    }
}

struct NavRow<Icon: View>: View {
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
        .accessibilityLabel(title)
        .accessibilityValue(String(count))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
