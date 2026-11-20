import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Every highlight from every PDF, for revising: from all PDFs, one
/// collection or one PDF; newest first or in reading order, optionally
/// grouped by PDF; filtered by color, by open or answered questions, and
/// by the header search. Clicking one opens the PDF at that spot; each card
/// can be edited right here, and Export saves what's shown as Markdown.
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
    /// For the menu of PDFs and collections to show.
    var entries: [LibraryEntry] = []
    var collections: [PDFCollection] = []
    let onOpen: (HighlightRecord) -> Void
    /// Opens a PDF at a page (0-based), or where she left off for `nil`.
    var onOpenPDF: (LibraryEntry, Int?) -> Void = { _, _ in }

    /// Kept for the window while she reads a PDF from the list and comes back.
    @SceneStorage("highlightsSource") private var sourceValue = ""
    @SceneStorage("highlightsQuestionStatus") private var status = QuestionStatus.all
    /// Remembered between launches: how she likes to revise.
    @AppStorage("highlightsOrder") private var order = HighlightOrder.newestFirst
    @AppStorage("highlightsGroupByPDF") private var groupsByPDF = false
    @State private var width: CGFloat = 1000

    static let cardSpacing: CGFloat = 12
    /// Cards sit side by side once each can be at least this wide…
    static let cardMinWidth: CGFloat = 420
    /// …and are never wider than this, so their text stays easy to read.
    static let cardMaxWidth: CGFloat = 600

    /// How many cards fit side by side in `width`: one in a narrow window,
    /// two on a laptop, three on a big display.
    static func columnCount(forWidth width: CGFloat) -> Int {
        max(1, min(4, Int((width + cardSpacing) / (cardMinWidth + cardSpacing))))
    }

    // MARK: What's shown

    /// The chosen PDFs, or all of them if the chosen collection or PDF is gone.
    private var source: ReviewSource {
        switch ReviewSource(storageValue: sourceValue) {
        case .all: .all
        case .collection(let id): collections.contains { $0.id == id } ? .collection(id) : .all
        case .entry(let id): entries.contains { $0.id == id } ? .entry(id) : .all
        }
    }

    private var filter: HighlightFilter {
        HighlightFilter(source: source, kinds: kinds, status: status, query: searchText)
    }

    private var sections: [HighlightSection] {
        let filter = filter
        return HighlightList.sections(
            highlights: records.filter(filter.includes),
            pageNotes: pageNotes.filter(filter.includes),
            summaries: summaries.filter(filter.includesSummary),
            order: order,
            groupsByPDF: groupsByPDF
        )
    }

    private var sourceTitle: String {
        switch source {
        case .all: "All PDFs"
        case .collection(let id): collections.first { $0.id == id }?.name ?? "All PDFs"
        case .entry(let id): entries.first { $0.id == id }?.title ?? "All PDFs"
        }
    }

    private func countLabel(_ sections: [HighlightSection]) -> String {
        let count = sections.reduce(0) { $0 + $1.items.count }
        if isNotesPage { return count == 1 ? "1 note" : "\(count) notes" }
        return count == 1 ? "1 highlight" : "\(count) highlights"
    }

    var body: some View {
        let sections = sections
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(Theme.display(32))
                    .tracking(-0.9)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(countLabel(sections))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkMuted)
                Spacer(minLength: 12)
                SecondaryButton(title: "Export as Markdown\u{2026}", systemImage: "square.and.arrow.down") {
                    export(sections)
                }
                .help("Save what\u{2019}s shown here as a Markdown file, by PDF and by color, with your notes and answers")
                .disabled(sections.isEmpty)
            }

            HStack(spacing: 6) {
                sourceMenu
                orderMenu
            }

            VStack(alignment: .leading, spacing: 8) {
                FlowLayout(spacing: 6) {
                    FilterChip(title: "All colors", isSelected: kinds.isEmpty) { kinds = [] }
                    ForEach(HighlightKind.allCases) { kind in
                        FilterChip(title: kind.name, dot: kind.vivid, isSelected: kinds.contains(kind)) {
                            if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
                        }
                    }
                }
                // Under the colors, as a choice within Questions.
                if kinds.contains(.question) {
                    statusChips
                }
            }

            if sections.isEmpty {
                emptyMessage
            } else {
                list(sections)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 64 } action: { width = $0 }
        // Open and Answered are for questions; without them, all are shown.
        .onChange(of: kinds) { if !kinds.contains(.question) { status = .all } }
        // File › Export as Markdown.
        .onReceive(NotificationCenter.default.publisher(for: .sheafExportShownHighlights)) { _ in
            let sections = self.sections
            if sections.isEmpty { NSSound.beep() } else { export(sections) }
        }
    }

    // MARK: The list

    private func list(_ sections: [HighlightSection]) -> some View {
        let columnCount = Self.columnCount(forWidth: width)
        let columns = Array(
            repeating: GridItem(.flexible(maximum: Self.cardMaxWidth), spacing: Self.cardSpacing, alignment: .top),
            count: columnCount
        )
        let gridWidth = CGFloat(columnCount) * Self.cardMaxWidth + CGFloat(columnCount - 1) * Self.cardSpacing
        return ScrollView {
            LazyVGrid(
                columns: columns, alignment: .leading, spacing: Self.cardSpacing,
                pinnedViews: groupsByPDF ? [.sectionHeaders] : []
            ) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            card(for: item)
                        }
                    } header: {
                        sectionHeader(section, isFirst: section.id == sections.first?.id)
                    }
                }
            }
            .frame(maxWidth: gridWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: HighlightSection, isFirst: Bool) -> some View {
        if let entry = section.entry {
            PDFGroupHeader(entry: entry, count: section.items.count, isNotesPage: isNotesPage) {
                onOpenPDF(entry, nil)
            }
            .padding(.top, isFirst ? 0 : 14)
            .background(Theme.background)
        } else if let title = section.title {
            SectionLabel(title: title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, isFirst ? 0 : 10)
        }
    }

    @ViewBuilder
    private func card(for item: HighlightItem) -> some View {
        switch item {
        case .highlight(let record):
            // Grouped by PDF, its heading already says which PDF.
            LibraryHighlightCard(record: record, showsTitle: !groupsByPDF) { onOpen(record) }
        case .page(let note):
            pageNoteCard(note)
        case .summary(let entry):
            summaryCard(entry)
        }
    }

    // MARK: Header controls

    private var sourceMenu: some View {
        Menu {
            Toggle("All PDFs", isOn: isChosen(.all))
            if !collections.isEmpty {
                Section("Collections") {
                    ForEach(collections) { collection in
                        Toggle(collection.name, isOn: isChosen(.collection(collection.id)))
                    }
                }
            }
            // Only PDFs with something on this page.
            let pdfs = pdfsWithItems.sorted(by: HighlightList.titleOrder)
            if !pdfs.isEmpty {
                Section("PDFs") {
                    ForEach(pdfs) { entry in
                        Toggle(entry.title, isOn: isChosen(.entry(entry.id)))
                    }
                }
            }
        } label: {
            MenuLabel(systemImage: "doc.on.doc", title: sourceTitle)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.sheaf(in: Capsule()))
        .fixedSize()
        .help("Choose which PDFs to show: all of them, a collection or one PDF")
        .accessibilityLabel("Show from")
        .accessibilityValue(sourceTitle)
    }

    private var orderMenu: some View {
        Menu {
            Section("Order") {
                ForEach(HighlightOrder.allCases) { option in
                    Toggle(option.title, isOn: Binding(get: { order == option }, set: { if $0 { order = option } }))
                }
            }
            Divider()
            Toggle("Group by PDF", isOn: $groupsByPDF)
        } label: {
            MenuLabel(
                systemImage: "arrow.up.arrow.down",
                title: groupsByPDF ? "\(order.title), by PDF" : order.title
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.sheaf(in: Capsule()))
        .fixedSize()
        .help("Newest first, or in reading order (by PDF, then page); optionally grouped by PDF")
        .accessibilityLabel("Order")
        .accessibilityValue(groupsByPDF ? "\(order.title), grouped by PDF" : order.title)
    }

    /// Open and Answered, for the questions shown, with how many of each.
    private var statusChips: some View {
        let filter = HighlightFilter(source: source, kinds: [.question], query: searchText)
        let questions = records.filter { $0.kind == .question && filter.includes($0) }
        let open = questions.count { !$0.isAnswered }
        return HStack(spacing: 6) {
            FilterChip(title: "Open questions \u{00B7} \(open)", isSelected: status == .open) {
                status = status == .open ? .all : .open
            }
            .help("Show only the questions you haven\u{2019}t answered yet")
            FilterChip(title: "Answered \u{00B7} \(questions.count - open)", isSelected: status == .answered) {
                status = status == .answered ? .all : .answered
            }
            .help("Show only the questions you\u{2019}ve answered")
        }
    }

    private var pdfsWithItems: [LibraryEntry] {
        var seen = Set<UUID>()
        let all = records.compactMap(\.entry) + pageNotes.compactMap(\.entry) + summaries
        return all.filter { seen.insert($0.id).inserted }
    }

    private func isChosen(_ option: ReviewSource) -> Binding<Bool> {
        Binding(get: { source == option }, set: { if $0 { sourceValue = option.storageValue } })
    }

    // MARK: Empty

    /// Says which choice is hiding everything, and offers to undo it.
    @ViewBuilder
    private var emptyMessage: some View {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if records.isEmpty && pageNotes.isEmpty && summaries.isEmpty {
            EmptyMessage(
                systemImage: isNotesPage ? "text.bubble" : "highlighter",
                title: "Nothing here yet",
                message: isNotesPage
                    ? "Notes you write on highlights and pages, and your summaries of PDFs, show up here."
                    : "Open a PDF, select some text and press 1\u{2013}4. Every highlight you make shows up here."
            )
        } else if !query.isEmpty {
            EmptyMessage(systemImage: "magnifyingglass", title: "No matches", message: "Try another search.")
        } else if filter.effectiveStatus == .open {
            EmptyMessage(
                systemImage: "checkmark.circle",
                title: "No open questions",
                message: "You\u{2019}ve answered every question here.",
                actionTitle: "Show All Questions"
            ) { status = .all }
        } else if filter.effectiveStatus == .answered {
            EmptyMessage(
                systemImage: "questionmark.bubble",
                title: "No answered questions yet",
                message: "Answer a Question highlight and it shows up here.",
                actionTitle: "Show All Questions"
            ) { status = .all }
        } else if !kinds.isEmpty {
            EmptyMessage(
                systemImage: "highlighter",
                title: "No matches",
                message: "No highlights of \(kinds.count == 1 ? "this color" : "these colors") \(source == .all ? "match" : "in \u{201C}\(sourceTitle)\u{201D}").",
                actionTitle: "Show All Colors"
            ) { kinds = [] }
        } else {
            EmptyMessage(
                systemImage: "doc.on.doc",
                title: "Nothing in \u{201C}\(sourceTitle)\u{201D}",
                message: isNotesPage ? "Its PDFs have no notes yet." : "Its PDFs have no highlights yet.",
                actionTitle: "Show All PDFs"
            ) { sourceValue = ReviewSource.all.storageValue }
        }
    }

    // MARK: Export

    private func export(_ sections: [HighlightSection]) {
        // A note or summary being typed is saved first, so it's in the file.
        NotificationCenter.default.post(name: .sheafFlushSaves, object: nil)
        let text = HighlightsMarkdown.export(title: title, details: exportDetails(sections), sections: sections)
        // "Highlights.md", or "Thesis highlights.md" for a collection or PDF.
        let name = source == .all ? title : "\(sourceTitle) \(title.lowercased())"
        MarkdownFile.save(text, suggestedName: "\(name).md")
    }

    /// What was shown, for the top of the export: "From “Thesis” · Question ·
    /// Open questions only · 4 highlights".
    private func exportDetails(_ sections: [HighlightSection]) -> String {
        var parts = [source == .all ? "From all PDFs" : "From \u{201C}\(sourceTitle)\u{201D}"]
        if !kinds.isEmpty {
            parts.append(HighlightKind.allCases.filter(kinds.contains).map(\.name).formatted(.list(type: .and)))
        }
        switch filter.effectiveStatus {
        case .all: break
        case .open: parts.append("Open questions only")
        case .answered: parts.append("Answered questions only")
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { parts.append("Matching \u{201C}\(query)\u{201D}") }
        parts.append(countLabel(sections))
        return parts.joined(separator: " \u{00B7} ")
    }

    /// What VoiceOver reads for a highlight card.
    static func spokenLabel(for record: HighlightRecord) -> String {
        let kind = record.isAnsweredQuestion ? "Answered question" : record.kind.name
        var label = "\(kind): \(record.text). \(record.entry?.title ?? "PDF"), page \(record.displayPage)"
        if !record.note.isEmpty { label += ". Note: \(record.note)" }
        if record.isAnsweredQuestion && !record.answer.isEmpty { label += ". Answer: \(record.answer)" }
        return label
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

/// A PDF's heading when the page is grouped by PDF: its title, collection
/// and how many cards it has. Click it to open the PDF.
private struct PDFGroupHeader: View {
    let entry: LibraryEntry
    let count: Int
    let isNotesPage: Bool
    let open: () -> Void

    private var countLabel: String {
        isNotesPage ? (count == 1 ? "1 note" : "\(count) notes") : (count == 1 ? "1 highlight" : "\(count) highlights")
    }

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.title)
                    .font(Theme.display(17))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let collection = entry.collection {
                    HStack(spacing: 5) {
                        Swatch(color: Theme.collectionColor(collection.colorIndex), size: 9)
                        Text(collection.name).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkSecondary)
                }
                Text(countLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                    .fixedSize()
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .buttonStyle(.sheaf(cornerRadius: 8))
        .help("Open \u{201C}\(entry.title)\u{201D}")
        .accessibilityLabel([entry.title, entry.collection?.name, countLabel].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the PDF")
        .accessibilityAddTraits(.isHeader)
        .contextMenu {
            Button("Open PDF", action: open)
        }
    }
}

/// The label of a menu in a page header: an icon, the choice, a chevron.
struct MenuLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 13)
        .frame(maxWidth: 280)
        .frame(height: 30)
        .overlay(Capsule().strokeBorder(Theme.control, lineWidth: 1))
    }
}

extension ReviewSource {
    /// For keeping the choice in scene storage: "", "collection:<id>" or "pdf:<id>".
    var storageValue: String {
        switch self {
        case .all: ""
        case .collection(let id): "collection:\(id.uuidString)"
        case .entry(let id): "pdf:\(id.uuidString)"
        }
    }

    init(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else {
            self = .all
            return
        }
        switch parts[0] {
        case "collection": self = .collection(id)
        case "pdf": self = .entry(id)
        default: self = .all
        }
    }
}
