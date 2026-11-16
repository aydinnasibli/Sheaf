import Foundation
import PDFKit
import Testing
@testable import Sheaf

@MainActor
struct ReaderModelTests {
    private func search(_ model: ReaderModel, for query: String) async throws {
        model.searchQuery = query
        model.search()
        try await waitUntil { !model.isSearching }
    }

    @Test func searchFindsEveryMatchInDocumentOrder() async throws {
        let model = ReaderModel(
            document: TestPDF.make(pages: ["The quick brown fox", "Nothing here", "Another fox and a FOX"]),
            entry: nil, store: nil, fileURL: nil
        )

        try await search(model, for: "fox")

        #expect(model.searchResults.count == 3)
        #expect(model.searchResults.map(\.pageLabel) == ["1", "3", "3"])
        #expect(model.pdfView.highlightedSelections?.count == 3)
    }

    @Test func newQueryReplacesPreviousResults() async throws {
        let model = ReaderModel(document: TestPDF.make(pages: ["brown fox", "fox", "fox"]), entry: nil, store: nil, fileURL: nil)

        // Start one search, then replace it before it can finish.
        model.searchQuery = "fox"
        model.search()
        try await search(model, for: "brown")

        #expect(model.searchResults.count == 1)
        #expect(model.searchResults.allSatisfy { $0.selection.string?.lowercased() == "brown" })
    }

    @Test func clearingQueryClearsResultsAndHighlights() async throws {
        let model = ReaderModel(document: TestPDF.make(pages: ["fox"]), entry: nil, store: nil, fileURL: nil)
        model.isSearchBarVisible = true
        try await search(model, for: "fox")
        #expect(model.isShowingSearchResults)

        try await search(model, for: "   ")

        #expect(model.searchResults.isEmpty)
        #expect(model.pdfView.highlightedSelections == nil)
        #expect(!model.isShowingSearchResults)
    }

    @Test func nextAndPreviousResultWrapAround() async throws {
        let model = ReaderModel(document: TestPDF.make(pages: ["fox", "fox", "fox"]), entry: nil, store: nil, fileURL: nil)
        try await search(model, for: "fox")
        try #require(model.searchResults.count == 3)

        model.selectNextResult()
        #expect(model.selectedResultID == 0)
        model.selectNextResult()
        model.selectNextResult()
        #expect(model.selectedResultID == 2)
        model.selectNextResult()
        #expect(model.selectedResultID == 0)
        model.selectPreviousResult()
        #expect(model.selectedResultID == 2)
    }

    @Test func snippetShowsTheLineWithTheMatchInBold() async throws {
        let model = ReaderModel(document: TestPDF.make(pages: ["The quick brown fox"]), entry: nil, store: nil, fileURL: nil)
        try await search(model, for: "brown")

        let snippet = try #require(model.searchResults.first?.snippet)
        #expect(String(snippet.characters) == "The quick brown fox")
        let bold = snippet.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(snippet[$0.range].characters) }
        #expect(bold == ["brown"])
    }

    @Test func goToPageIgnoresNumbersOutsideTheDocument() {
        let model = ReaderModel(document: TestPDF.make(pages: ["one", "two"]), entry: nil, store: nil, fileURL: nil)

        model.goToPage(number: 0)
        model.goToPage(number: 3)
        model.goToPage(number: -5)

        #expect(model.currentPageIndex == 0)
    }

    @Test func outlineMirrorsThePDFTableOfContents() throws {
        let document = TestPDF.make(pages: ["one", "two"])
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter 1"
        chapter.destination = PDFDestination(page: try #require(document.page(at: 0)), at: .zero)
        let section = PDFOutline()
        section.label = "Section 1.1"
        section.destination = PDFDestination(page: try #require(document.page(at: 1)), at: .zero)
        chapter.insertChild(section, at: 0)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root

        let model = ReaderModel(document: document, entry: nil, store: nil, fileURL: nil)

        #expect(model.outline.map(\.title) == ["Chapter 1"])
        #expect(model.outline.first?.children?.map(\.title) == ["Section 1.1"])
        #expect(model.outline.first?.children?.first?.children == nil)

        // The Contents list: flattened, indented, with start pages.
        #expect(model.outlineRows.map(\.title) == ["Chapter 1", "Section 1.1"])
        #expect(model.outlineRows.map(\.depth) == [0, 1])
        #expect(model.outlineRows.map(\.pageIndex) == [0, 1])
        #expect(model.currentOutlineRowID == 0)
    }

    @Test func emptyOutlineWhenPDFHasNone() {
        let model = ReaderModel(document: TestPDF.make(pages: ["one"]), entry: nil, store: nil, fileURL: nil)
        #expect(model.outline.isEmpty)
    }
}
