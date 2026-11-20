import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Every highlight from every PDF, newest first, filterable by color and
/// searchable from the header. Clicking one opens the PDF at that spot.
/// The Notes page shows highlights with a note, and also page notes and
/// each PDF's summary.
struct HighlightsPage: View {
    let title: String
    let records: [HighlightRecord]
    /// Notes on whole pages, newest first (the Notes page only).
    var pageNotes: [PageNote] = []
    /// PDFs with a summary (the Notes page only).
    var summaries: [LibraryEntry] = []
    var isNotesPage = false
    let searchText: String
    /// The colors shown; empty means all. Shared with the sidebar's color rows.
    @Binding var kinds: Set<HighlightKind>
    let onOpen: (HighlightRecord) -> Void
    /// Opens a PDF at a page (0-based), or where she left off for `nil`.
    var onOpenPDF: (LibraryEntry, Int?) -> Void = { _, _ in }

    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }

    private var shown: [HighlightRecord] {
        records.filter { record in
            (kinds.isEmpty || kinds.contains(record.kind))
                && (query.isEmpty
                    || record.text.localizedStandardContains(query)
                    || record.note.localizedStandardContains(query)
                    || (record.entry?.title.localizedStandardContains(query) ?? false))
        }
    }

    /// Page notes have no color, so a color filter hides them.
    private var shownPageNotes: [PageNote] {
        guard kinds.isEmpty else { return [] }
        return pageNotes.filter { note in
            note.entry != nil
                && (query.isEmpty
                    || note.text.localizedStandardContains(query)
                    || (note.entry?.title.localizedStandardContains(query) ?? false))
        }
    }

    private var shownSummaries: [LibraryEntry] {
        guard kinds.isEmpty else { return [] }
        return summaries.filter { entry in
            !entry.summary.isEmpty
                && (query.isEmpty || entry.summary.localizedStandardContains(query) || entry.title.localizedStandardContains(query))
        }
    }

    /// Highlights and page notes together, newest first.
    private var items: [Item] {
        let notes = shownPageNotes
        let highlights = shown.map(Item.highlight)
        guard !notes.isEmpty else { return highlights }
        return (highlights + notes.map(Item.page)).sorted { $0.createdAt > $1.createdAt }
    }

    private var countLabel: String {
        guard isNotesPage else { return shown.count == 1 ? "1 highlight" : "\(shown.count) highlights" }
        let count = shown.count + shownPageNotes.count + shownSummaries.count
        return count == 1 ? "1 note" : "\(count) notes"
    }

    var body: some View {
        let items = items
        let summaries = shownSummaries
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(Theme.display(32))
                    .tracking(-0.9)
                    .foregroundStyle(Theme.ink)
                Text(countLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkMuted)
            }

            FlowLayout(spacing: 6) {
                FilterChip(title: "All colors", isSelected: kinds.isEmpty) { kinds = [] }
                ForEach(HighlightKind.allCases) { kind in
                    FilterChip(title: kind.name, dot: kind.vivid, isSelected: kinds.contains(kind)) {
                        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
                    }
                }
            }

            if items.isEmpty && summaries.isEmpty {
                if records.isEmpty && pageNotes.isEmpty && self.summaries.isEmpty {
                    EmptyMessage(
                        systemImage: isNotesPage ? "text.bubble" : "highlighter",
                        title: "Nothing here yet",
                        message: isNotesPage
                            ? "Notes you write on highlights and pages, and your summaries of PDFs, show up here."
                            : "Open a PDF, select some text and press 1\u{2013}4. Every highlight you make shows up here."
                    )
                } else if kinds.isEmpty {
                    EmptyMessage(systemImage: "magnifyingglass", title: "No matches", message: "Try another search.")
                } else {
                    EmptyMessage(
                        systemImage: "highlighter",
                        title: "No matches",
                        message: "No highlights of \(kinds.count == 1 ? "this color" : "these colors") match.",
                        actionTitle: "Show All Colors"
                    ) { kinds = [] }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !summaries.isEmpty {
                            SectionLabel(title: "Summaries")
                            ForEach(summaries) { entry in
                                summaryCard(entry)
                            }
                            if !items.isEmpty {
                                SectionLabel(title: "Notes").padding(.top, 10)
                            }
                        }
                        ForEach(items) { item in
                            switch item {
                            case .highlight(let record): highlightCard(record)
                            case .page(let note): pageNoteCard(note)
                            }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What VoiceOver reads for a highlight card.
    static func spokenLabel(for record: HighlightRecord) -> String {
        var label = "\(record.kind.name): \(record.text). \(record.entry?.title ?? "PDF"), page \(record.displayPage)"
        if !record.note.isEmpty { label += ". Note: \(record.note)" }
        return label
    }

    // MARK: Highlights

    private func highlightCard(_ record: HighlightRecord) -> some View {
        Button { onOpen(record) } label: { card(record) }
            .buttonStyle(.sheaf(.overlay, cornerRadius: 12))
            .accessibilityLabel(Self.spokenLabel(for: record))
            .accessibilityAction(named: "Copy as quote") { Citation.copy(record.quote) }
            .help("Open \u{201C}\(record.entry?.title ?? "PDF")\u{201D} at page \(record.displayPage). Drag it out of Sheaf to drop it as a quote.")
            // Dropped into an essay, it arrives as a quote with its source.
            .onDrag { Citation.dragItem(record.quote) }
            .contextMenu {
                Button("Open in PDF") { onOpen(record) }
                Button("Copy Text") { Citation.copy(record.text) }
                Button("Copy as Quote") { Citation.copy(record.quote) }
            }
    }

    private func card(_ record: HighlightRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(record.kind.name.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(record.kind.chipText)
                Spacer()
                Text(record.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Text(record.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading)
            if !record.note.isEmpty {
                Text(record.note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.leading)
            }
            Text("\(record.entry?.title ?? "PDF") \u{00B7} p. \(record.displayPage)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(record.kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Page notes and summaries

    private func pageNoteCard(_ note: PageNote) -> some View {
        let title = note.entry?.title ?? "PDF"
        return Button {
            if let entry = note.entry { onOpenPDF(entry, note.pageIndex) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("PAGE NOTE", systemImage: "note.text")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.inkSecondary)
                    Spacer()
                    Text(note.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Text(note.text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                Text("\(title) \u{00B7} p. \(note.displayPage)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.sheaf(.overlay, cornerRadius: 12))
        .accessibilityLabel("Page note: \(note.text). \(title), page \(note.displayPage)")
        .help("Open \u{201C}\(title)\u{201D} at page \(note.displayPage)")
        .contextMenu {
            Button("Open in PDF") { if let entry = note.entry { onOpenPDF(entry, note.pageIndex) } }
            Button("Copy Text") { Citation.copy(note.text) }
        }
    }

    private func summaryCard(_ entry: LibraryEntry) -> some View {
        Button { onOpenPDF(entry, nil) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("MY SUMMARY")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.inkSecondary)
                Text(entry.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(10)
                    .multilineTextAlignment(.leading)
                Text(entry.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.sheaf(.overlay, cornerRadius: 12))
        .accessibilityLabel("Summary of \(entry.title): \(entry.summary)")
        .help("Open \u{201C}\(entry.title)\u{201D}")
        .contextMenu {
            Button("Open PDF") { onOpenPDF(entry, nil) }
            Button("Copy Summary") { Citation.copy(entry.summary) }
        }
    }
}

/// A highlight or a page note in the list.
private enum Item: Identifiable {
    case highlight(HighlightRecord)
    case page(PageNote)

    var id: UUID {
        switch self {
        case .highlight(let record): record.id
        case .page(let note): note.id
        }
    }

    var createdAt: Date {
        switch self {
        case .highlight(let record): record.createdAt
        case .page(let note): note.createdAt
        }
    }
}
