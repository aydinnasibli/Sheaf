import Foundation

/// The order of the Highlights and Notes pages.
enum HighlightOrder: String, CaseIterable, Identifiable {
    /// Newest first, as made.
    case newestFirst
    /// As they come in each PDF: PDFs by title, then page, then from the
    /// top of the page down. For revising a reading from start to end.
    case readingOrder

    var id: Self { self }

    var title: String {
        switch self {
        case .newestFirst: "Newest First"
        case .readingOrder: "Reading Order"
        }
    }
}

/// Which questions are shown while the Question color is: all of them,
/// only the open ones, or only the answered ones.
enum QuestionStatus: String, CaseIterable, Identifiable {
    case all, open, answered

    var id: Self { self }
}

/// What the Highlights and Notes pages show: the PDFs (all, a collection or
/// one PDF), the colors, open or answered questions, and the search.
struct HighlightFilter {
    var source = ReviewSource.all
    /// The colors shown; empty means all.
    var kinds: Set<HighlightKind> = []
    var status = QuestionStatus.all
    var query = ""

    /// Open and Answered only mean something for questions, so they apply
    /// while the Question color is chosen.
    var effectiveStatus: QuestionStatus { kinds.contains(.question) ? status : .all }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    func includes(_ record: HighlightRecord) -> Bool {
        guard isInSource(record.entry), kinds.isEmpty || kinds.contains(record.kind) else { return false }
        if record.kind == .question {
            switch effectiveStatus {
            case .all: break
            case .open: guard !record.isAnswered else { return false }
            case .answered: guard record.isAnswered else { return false }
            }
        }
        let query = trimmedQuery
        return query.isEmpty
            || record.text.localizedStandardContains(query)
            || record.note.localizedStandardContains(query)
            || (record.isAnsweredQuestion && record.answer.localizedStandardContains(query))
            || (record.entry?.title.localizedStandardContains(query) ?? false)
    }

    /// Page notes have no color, so a color filter hides them.
    func includes(_ note: PageNote) -> Bool {
        guard kinds.isEmpty, let entry = note.entry, isInSource(entry) else { return false }
        let query = trimmedQuery
        return query.isEmpty || note.text.localizedStandardContains(query) || entry.title.localizedStandardContains(query)
    }

    /// A PDF's summary, on the Notes page. Hidden by a color filter, like page notes.
    func includesSummary(of entry: LibraryEntry) -> Bool {
        guard kinds.isEmpty, !entry.summary.isEmpty, isInSource(entry) else { return false }
        let query = trimmedQuery
        return query.isEmpty || entry.summary.localizedStandardContains(query) || entry.title.localizedStandardContains(query)
    }

    private func isInSource(_ entry: LibraryEntry?) -> Bool {
        guard source != .all else { return true }
        return entry.map(source.contains) ?? false
    }
}

/// One card on the Highlights or Notes page.
enum HighlightItem: Identifiable {
    case highlight(HighlightRecord)
    case page(PageNote)
    /// A PDF's summary (the Notes page only).
    case summary(LibraryEntry)

    var id: UUID {
        switch self {
        case .highlight(let record): record.id
        case .page(let note): note.id
        case .summary(let entry): entry.id
        }
    }

    var entry: LibraryEntry? {
        switch self {
        case .highlight(let record): record.entry
        case .page(let note): note.entry
        case .summary(let entry): entry
        }
    }

    /// A summary has no date of its own; it goes with when its PDF was last read.
    var date: Date {
        switch self {
        case .highlight(let record): record.createdAt
        case .page(let note): note.createdAt
        case .summary(let entry): entry.lastOpenedAt
        }
    }
}

/// A run of cards under one heading: a PDF when grouped by PDF, else
/// "Summaries" and "Notes" on the Notes page, or no heading at all.
struct HighlightSection: Identifiable {
    let id: String
    /// The PDF, when grouped by PDF.
    var entry: LibraryEntry?
    /// A plain heading, like "Summaries", when not grouped.
    var title: String?
    let items: [HighlightItem]

    var highlights: [HighlightRecord] {
        items.compactMap { if case .highlight(let record) = $0 { record } else { nil } }
    }
}

enum HighlightList {
    /// The cards in order, grouped by PDF or not. Summaries come first: in
    /// their own section, or at the top of their PDF's.
    static func sections(
        highlights: [HighlightRecord], pageNotes: [PageNote] = [], summaries: [LibraryEntry] = [],
        order: HighlightOrder, groupsByPDF: Bool
    ) -> [HighlightSection] {
        let cards = sorted(highlights.map(HighlightItem.highlight) + pageNotes.map(HighlightItem.page), by: order)
        let summaryCards = sortedSummaries(summaries, by: order).map(HighlightItem.summary)

        guard groupsByPDF else {
            var sections: [HighlightSection] = []
            if !summaryCards.isEmpty {
                sections.append(HighlightSection(id: "summaries", title: "Summaries", items: summaryCards))
            }
            if !cards.isEmpty {
                sections.append(HighlightSection(id: "items", title: summaryCards.isEmpty ? nil : "Notes", items: cards))
            }
            return sections
        }

        // Each PDF where its first card is, so the groups keep the order.
        var groups: [UUID: [HighlightItem]] = [:]
        var entries: [UUID: LibraryEntry] = [:]
        var groupOrder: [UUID] = []
        for item in summaryCards + cards {
            guard let entry = item.entry else { continue }
            if groups[entry.id] == nil {
                groupOrder.append(entry.id)
                entries[entry.id] = entry
            }
            groups[entry.id, default: []].append(item)
        }
        let ordered = groupOrder.compactMap { entries[$0] }
        let pdfs: [LibraryEntry]
        switch order {
        case .readingOrder:
            pdfs = ordered.sorted(by: titleOrder)
        case .newestFirst:
            // By the newest highlight or note in each; a PDF with only a summary by when it was read.
            let newest = groupOrder.reduce(into: [UUID: Date]()) { dates, id in
                dates[id] = groups[id]?.map(\.date).max()
            }
            pdfs = ordered.sorted { (newest[$0.id] ?? .distantPast) > (newest[$1.id] ?? .distantPast) }
        }
        return pdfs.map { entry in
            HighlightSection(id: entry.id.uuidString, entry: entry, items: groups[entry.id] ?? [])
        }
    }

    static func sorted(_ items: [HighlightItem], by order: HighlightOrder) -> [HighlightItem] {
        switch order {
        case .newestFirst:
            items.sorted { $0.date > $1.date }
        case .readingOrder:
            items.sorted(by: readingOrder)
        }
    }

    /// PDFs by title, then page; on a page its note first, then highlights
    /// from the top down and, at the same height, from the left.
    static func readingOrder(_ a: HighlightItem, _ b: HighlightItem) -> Bool {
        if let pdfA = a.entry, let pdfB = b.entry, pdfA.id != pdfB.id {
            return titleOrder(pdfA, pdfB)
        }
        let (pageA, pageB) = (a.pageIndex, b.pageIndex)
        if pageA != pageB { return pageA < pageB }
        switch (a, b) {
        case (.page, .highlight): return true
        case (.highlight, .page): return false
        case (.highlight(let first), .highlight(let second)):
            if first.top != second.top { return first.top > second.top }
            if first.left != second.left { return first.left < second.left }
            return first.createdAt < second.createdAt
        default:
            return a.date < b.date
        }
    }

    private static func sortedSummaries(_ entries: [LibraryEntry], by order: HighlightOrder) -> [LibraryEntry] {
        switch order {
        case .newestFirst: entries.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        case .readingOrder: entries.sorted(by: titleOrder)
        }
    }

    /// PDFs by title as Finder sorts names; the same title by when it was added.
    static func titleOrder(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        switch a.title.localizedStandardCompare(b.title) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.addedAt == b.addedAt ? a.id.uuidString < b.id.uuidString : a.addedAt < b.addedAt
        }
    }

    /// The PDFs in the order their cards first appear.
    static func pdfs(in sections: [HighlightSection]) -> [LibraryEntry] {
        var seen = Set<UUID>()
        return sections.flatMap(\.items).compactMap(\.entry).filter { seen.insert($0.id).inserted }
    }
}

private extension HighlightItem {
    /// The page, for reading order; a summary goes before every page.
    var pageIndex: Int {
        switch self {
        case .highlight(let record): record.pageIndex
        case .page(let note): note.pageIndex
        case .summary: -1
        }
    }
}
