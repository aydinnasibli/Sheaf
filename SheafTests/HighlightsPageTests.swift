import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Sheaf

/// The library's Highlights page as a revision tool: which PDFs, the
/// order, open and answered questions, and exporting what's shown.
@MainActor
struct HighlightsPageTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    private func makeEntry(_ title: String, in collection: PDFCollection? = nil) -> LibraryEntry {
        let entry = LibraryEntry(title: title, path: "/Users/test/\(title).pdf", pageCount: 20, now: start)
        container.mainContext.insert(entry)
        entry.collection = collection
        return entry
    }

    /// A highlight made `minute` minutes after the start, with its top at `top` on the page.
    @discardableResult
    private func add(
        _ text: String, to entry: LibraryEntry, page: Int, top: Double = 700, left: Double = 72,
        kind: HighlightKind = .keyIdea, minute: Int
    ) -> HighlightRecord {
        store.addHighlight(
            to: entry, pageIndex: page, kind: kind, text: text,
            rects: [CGRect(x: left, y: top - 14, width: 100, height: 14)],
            now: start.addingTimeInterval(Double(minute) * 60)
        )
    }

    private func allHighlights() throws -> [HighlightRecord] {
        try container.mainContext.fetch(FetchDescriptor<HighlightRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    private func texts(_ sections: [HighlightSection]) -> [String] {
        sections.flatMap(\.items).map { item in
            switch item {
            case .highlight(let record): record.text
            case .page(let note): "note: \(note.text)"
            case .summary(let entry): "summary: \(entry.title)"
            }
        }
    }

    private func sections(
        _ filter: HighlightFilter = HighlightFilter(), order: HighlightOrder = .newestFirst, groupsByPDF: Bool = false,
        pageNotes: [PageNote] = []
    ) throws -> [HighlightSection] {
        HighlightList.sections(
            highlights: try allHighlights().filter(filter.includes), pageNotes: pageNotes.filter(filter.includes),
            order: order, groupsByPDF: groupsByPDF
        )
    }

    // MARK: Which PDFs

    @Test func theScopeIsAllPDFsACollectionOrOnePDF() throws {
        let thesis = store.createCollection(named: "Thesis")
        let attention = makeEntry("Attention", in: thesis)
        let contract = makeEntry("Contract")
        add("Self-attention", to: attention, page: 0, minute: 1)
        add("Clause 4", to: contract, page: 0, minute: 2)

        #expect(try texts(sections()) == ["Clause 4", "Self-attention"])
        #expect(try texts(sections(HighlightFilter(source: .collection(thesis.id)))) == ["Self-attention"])
        #expect(try texts(sections(HighlightFilter(source: .entry(contract.id)))) == ["Clause 4"])
    }

    @Test func theScopeIsRememberedAsText() {
        let id = UUID()
        for source in [ReviewSource.all, .collection(id), .entry(id)] {
            #expect(ReviewSource(storageValue: source.storageValue) == source)
        }
        #expect(ReviewSource(storageValue: "nonsense") == .all)
    }

    // MARK: Order

    @Test func readingOrderGoesByPDFThenPageThenDownThePage() throws {
        let second = makeEntry("B paper")
        let first = makeEntry("A paper")
        add("B, page 1", to: second, page: 0, minute: 1)
        add("A, page 3", to: first, page: 2, minute: 2)
        add("A, page 1, lower", to: first, page: 0, top: 400, minute: 3)
        add("A, page 1, top", to: first, page: 0, top: 700, minute: 4)
        add("A, page 1, lower, right", to: first, page: 0, top: 400, left: 300, minute: 0)
        let note = store.addPageNote(to: first, pageIndex: 0, text: "About page 1", createdAt: start.addingTimeInterval(600))

        #expect(try texts(sections(order: .readingOrder, pageNotes: [note])) == [
            "note: About page 1", "A, page 1, top", "A, page 1, lower", "A, page 1, lower, right", "A, page 3", "B, page 1",
        ])
        #expect(try texts(sections(order: .newestFirst, pageNotes: [note])) == [
            "note: About page 1", "A, page 1, top", "A, page 1, lower", "A, page 3", "B, page 1", "A, page 1, lower, right",
        ])
    }

    @Test func groupedByPDFEachPDFHasItsOwnSection() throws {
        let thesis = store.createCollection(named: "Thesis")
        let attention = makeEntry("Attention", in: thesis)
        let contract = makeEntry("Contract")
        add("Old one", to: attention, page: 0, minute: 1)
        add("Clause 4", to: contract, page: 1, minute: 2)
        add("New one", to: attention, page: 3, minute: 3)

        let newest = try sections(order: .newestFirst, groupsByPDF: true)
        #expect(newest.map(\.entry?.title) == ["Attention", "Contract"])
        #expect(newest.map(\.highlights.count) == [2, 1])
        #expect(texts(newest) == ["New one", "Old one", "Clause 4"])

        let reading = try sections(order: .readingOrder, groupsByPDF: true)
        #expect(reading.map(\.entry?.title) == ["Attention", "Contract"])
        #expect(texts(reading) == ["Old one", "New one", "Clause 4"])
    }

    // MARK: Open and answered questions

    @Test func questionsCanBeShownOpenOrAnswered() throws {
        let entry = makeEntry("Paper")
        let answered = add("Answered one", to: entry, page: 0, kind: .question, minute: 1)
        add("Open one", to: entry, page: 0, kind: .question, minute: 2)
        add("An idea", to: entry, page: 0, kind: .keyIdea, minute: 3)
        store.setAnswer("Yes", isAnswered: true, for: answered)

        let questions = HighlightFilter(kinds: [.question])
        #expect(try texts(sections(questions)) == ["Open one", "Answered one"])

        var open = questions
        open.status = .open
        #expect(try texts(sections(open)) == ["Open one"])

        var done = questions
        done.status = .answered
        #expect(try texts(sections(done)) == ["Answered one"])

        // With other colors too, only the questions are narrowed down.
        open.kinds = [.question, .keyIdea]
        #expect(try texts(sections(open)) == ["An idea", "Open one"])

        // Open and Answered are for questions; with every color shown, they don't apply.
        open.kinds = []
        #expect(open.effectiveStatus == .all)
        #expect(try texts(sections(open)).count == 3)
    }

    @Test func theSearchFindsAnswers() throws {
        let entry = makeEntry("Paper")
        let record = add("Why?", to: entry, page: 0, kind: .question, minute: 1)
        store.setAnswer("Because of the softmax", isAnswered: true, for: record)

        #expect(try texts(sections(HighlightFilter(query: "softmax"))) == ["Why?"])
    }

    // MARK: Width

    @Test func cardsSitSideBySideInAWideWindow() {
        // The page's width without its margins: a 680 pt window, a laptop, a big display.
        #expect(HighlightsPage.columnCount(forWidth: 616) == 1)
        #expect(HighlightsPage.columnCount(forWidth: 1085) == 2)
        #expect(HighlightsPage.columnCount(forWidth: 1639) == 3)
    }

    // MARK: Export

    @Test func theExportFollowsTheOrderShown() throws {
        let thesis = store.createCollection(named: "Thesis")
        let attention = makeEntry("Attention", in: thesis)
        let contract = makeEntry("Contract")
        let question = add("Why softmax", to: attention, page: 4, kind: .question, minute: 1)
        add("Self-attention", to: attention, page: 2, kind: .keyIdea, minute: 2)
        let idea = add("Scaled dot product", to: attention, page: 1, kind: .keyIdea, minute: 3)
        add("Hidden evidence", to: attention, page: 1, kind: .evidence, minute: 4)
        add("Clause 4", to: contract, page: 0, kind: .keyIdea, minute: 5)
        store.setNote("The core idea\nof the paper", for: idea)
        store.setAnswer("It keeps gradients stable", isAnswered: true, for: question)

        // Newest first, not grouped: one list, as on the page.
        let shown = try sections(HighlightFilter(kinds: [.keyIdea, .question]))
        let markdown = HighlightsMarkdown.export(title: "Highlights", details: "From all PDFs \u{00B7} 4 highlights", sections: shown)

        #expect(markdown == """
        # Highlights

        From all PDFs \u{00B7} 4 highlights

        - Key idea: \u{201C}Clause 4\u{201D} (Contract, p. 1)
        - Key idea: \u{201C}Scaled dot product\u{201D} (Attention, p. 2)
          - The core idea
            of the paper
        - Key idea: \u{201C}Self-attention\u{201D} (Attention, p. 3)
        - Question: \u{201C}Why softmax\u{201D} (Attention, p. 5)
          - Answer: It keeps gradients stable

        """)
        #expect(!markdown.contains("Hidden evidence"))
    }

    @Test func theExportKeepsTheGroupsShown() throws {
        let thesis = store.createCollection(named: "Thesis")
        let attention = makeEntry("Attention", in: thesis)
        let contract = makeEntry("Contract")
        let question = add("Why softmax", to: attention, page: 4, kind: .question, minute: 1)
        add("Self-attention", to: attention, page: 2, kind: .keyIdea, minute: 2)
        add("Scaled dot product", to: attention, page: 1, kind: .keyIdea, minute: 3)
        add("Clause 4", to: contract, page: 0, kind: .keyIdea, minute: 5)
        store.setAnswer("", isAnswered: true, for: question)

        // In reading order, grouped by PDF: each PDF under its heading.
        let grouped = try sections(order: .readingOrder, groupsByPDF: true)
        #expect(HighlightsMarkdown.export(title: "Highlights", details: "From all PDFs", sections: grouped) == """
        # Highlights

        From all PDFs

        ## Attention

        Collection: Thesis

        - Key idea: \u{201C}Scaled dot product\u{201D} (Attention, p. 2)
        - Key idea: \u{201C}Self-attention\u{201D} (Attention, p. 3)
        - Question: \u{201C}Why softmax\u{201D} (Attention, p. 5)
          - Answered

        ## Contract

        - Key idea: \u{201C}Clause 4\u{201D} (Contract, p. 1)

        """)

        // With one color shown, the highlights don't each repeat it.
        let ideas = try sections(HighlightFilter(kinds: [.keyIdea]), order: .readingOrder)
        let markdown = HighlightsMarkdown.export(title: "Highlights", details: "Key idea", sections: ideas)
        #expect(markdown.contains("\n- \u{201C}Scaled dot product\u{201D} (Attention, p. 2)\n- \u{201C}Self-attention\u{201D} (Attention, p. 3)\n- \u{201C}Clause 4\u{201D} (Contract, p. 1)\n"))
    }

    @Test func theNotesExportHasSummariesAndPageNotes() throws {
        let entry = makeEntry("Attention")
        entry.summary = "About attention."
        let record = add("Self-attention", to: entry, page: 0, minute: 1)
        store.setNote("Key", for: record)
        let note = store.addPageNote(to: entry, pageIndex: 2, text: "The diagram", createdAt: start.addingTimeInterval(120))

        let shown = HighlightList.sections(
            highlights: [record], pageNotes: [note], summaries: [entry], order: .readingOrder, groupsByPDF: true
        )
        #expect(texts(shown) == ["summary: Attention", "Self-attention", "note: The diagram"])

        let markdown = HighlightsMarkdown.export(title: "Notes", details: "From all PDFs", sections: shown)
        #expect(markdown.contains("## Attention\n\n**My summary:** About attention.\n\n- \u{201C}Self-attention\u{201D} (Attention, p. 1)\n  - Key\n- Page note: The diagram (Attention, p. 3)\n"))

        // Not grouped, summaries come first under their own heading, as on the page.
        let flat = HighlightList.sections(
            highlights: [record], pageNotes: [note], summaries: [entry], order: .newestFirst, groupsByPDF: false
        )
        #expect(flat.map(\.title) == ["Summaries", "Notes"])
        let flatMarkdown = HighlightsMarkdown.export(title: "Notes", details: "From all PDFs", sections: flat)
        #expect(flatMarkdown.contains("## Summaries\n\n- **Attention:** About attention.\n\n## Notes\n\n- Page note: The diagram (Attention, p. 3)\n- \u{201C}Self-attention\u{201D} (Attention, p. 1)\n"))
    }
}
