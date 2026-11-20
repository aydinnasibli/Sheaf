import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Printed page numbers, Go to Page, and Copy as Quote.
@MainActor
struct PageLabelAndQuoteTests {
    private let container: ModelContainer
    private let store: LibraryStore

    /// i, ii, then 245, 246: a preface, then a journal article's pages.
    private static let pages = ["Cover page", "Preface text", "Chapter one begins", "More text here"]
    private static let labels = "0 << /S /r >> 2 << /S /D /St 245 >>"

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    private func makeReader(url: URL) throws -> ReaderModel {
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        return ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences)
    }

    private func select(_ text: String, in model: ReaderModel) throws {
        model.pdfView.currentSelection = try #require(model.document.findString(text, withOptions: []).first)
    }

    /// Puts the page view in a window (never shown), so turning pages works.
    private func showPages(of model: ReaderModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = model.pdfView
        model.layout = .single
        model.restoreReadingPosition()
        return window
    }

    // MARK: Page labels

    @Test func printedLabelsAreReadAndPlainNumbersAreNot() {
        #expect(PageLabels.read(from: TestPDF.make(pages: Self.pages, labels: Self.labels)) == ["i", "ii", "245", "246"])
        // PDFKit calls an unlabeled page "1", "2"…: no labels to show.
        #expect(PageLabels.read(from: TestPDF.make(pages: ["One", "Two"])).isEmpty)
    }

    @Test func theReaderShowsPrintedLabelsAndFallsBackToNumbers() throws {
        let labeled = try makeReader(url: try TestFiles.pdf(pages: Self.pages, labels: Self.labels))
        #expect(labeled.pageLabel(at: 0) == "i")
        #expect(labeled.pageLabel(at: 2) == "245")
        #expect(labeled.pageLabel == "i")
        #expect(labeled.pagePosition == "1")
        labeled.layout = .twoPages
        #expect(labeled.pageLabel == "i\u{2013}ii")
        #expect(labeled.goToPagePrompt.contains("as it\u{2019}s printed"))

        let plain = try makeReader(url: try TestFiles.pdf(pages: ["One", "Two"]))
        #expect(plain.pageLabels.isEmpty)
        #expect(plain.pageLabel(at: 1) == "2")
        #expect(plain.pageLabel == plain.pagePosition)
        #expect(plain.goToPagePrompt == "Enter a page number from 1 to 2.")
    }

    @Test func highlightsKeepTheirPrintedPage() throws {
        let model = try makeReader(url: try TestFiles.pdf(pages: Self.pages, labels: Self.labels))
        try select("Chapter one", in: model)
        model.highlightSelection(as: .evidence)

        let record = try #require(model.highlights.first)
        #expect(record.pageIndex == 2)
        #expect(record.pageLabel == "245")
        #expect(record.displayPage == "245")
        // The library remembers the PDF's labels too.
        #expect(model.entry?.pageLabels == ["i", "ii", "245", "246"])
    }

    @Test func olderHighlightsFallBackToTheRememberedLabelOrTheNumber() throws {
        let entry = LibraryEntry(title: "Paper", path: "/tmp/Paper-\(UUID()).pdf", pageCount: 4)
        container.mainContext.insert(entry)
        let record = store.addHighlight(to: entry, pageIndex: 2, kind: .keyIdea, text: "Old", rects: [])
        #expect(record.pageLabel.isEmpty)
        #expect(record.displayPage == "3")

        entry.pageLabels = ["i", "ii", "245", "246"]
        #expect(record.displayPage == "245")
        // Labels for a different number of pages (the file changed) aren't used.
        entry.pageLabels = ["i", "ii"]
        #expect(record.displayPage == "3")
    }

    @Test func labelsSurviveSheafSavingIntoTheFile() async throws {
        let url = try TestFiles.pdf(pages: Self.pages, labels: Self.labels)
        let model = try makeReader(url: url)
        try select("Chapter one", in: model)
        model.highlightSelection(as: .keyIdea)
        // Saving rewrites the file with PDFKit, which may drop its labels.
        await model.saveAndWait()

        let reopened = ReaderModel(document: try #require(PDFDocument(url: url)), entry: model.entry, store: store, fileURL: url)
        #expect(reopened.pageLabels == ["i", "ii", "245", "246"])
        #expect(reopened.pageLabel(at: 3) == "246")
    }

    // MARK: Go to Page

    @Test func goToPageFindsTheLabelThenTheNumber() {
        let labels = ["i", "ii", "1", "2"]
        #expect(PageLabels.pageIndex(for: "ii", labels: labels, pageCount: 4) == 1)
        #expect(PageLabels.pageIndex(for: " II ", labels: labels, pageCount: 4) == 1)
        // A printed number wins over counting from the start…
        #expect(PageLabels.pageIndex(for: "1", labels: labels, pageCount: 4) == 2)
        // …and counting from the start works when no page is printed that way.
        #expect(PageLabels.pageIndex(for: "3", labels: labels, pageCount: 4) == 2)
        #expect(PageLabels.pageIndex(for: "4", labels: [], pageCount: 4) == 3)
        #expect(PageLabels.pageIndex(for: "5", labels: labels, pageCount: 4) == nil)
        #expect(PageLabels.pageIndex(for: "0", labels: labels, pageCount: 4) == nil)
        #expect(PageLabels.pageIndex(for: "xii", labels: labels, pageCount: 4) == nil)
        #expect(PageLabels.pageIndex(for: "", labels: labels, pageCount: 4) == nil)
    }

    @Test func goToPageGoesToAPrintedPage() throws {
        let model = try makeReader(url: try TestFiles.pdf(pages: Self.pages, labels: Self.labels))
        let window = showPages(of: model)
        defer { window.contentView = nil }

        #expect(model.goToPage(typed: "245"))
        #expect(model.pdfView.currentPage == model.document.page(at: 2))
        #expect(model.goToPage(typed: "ii"))
        #expect(model.pdfView.currentPage == model.document.page(at: 1))
        // No page is printed "4", so it's the fourth page.
        #expect(model.goToPage(typed: "4"))
        #expect(model.pdfView.currentPage == model.document.page(at: 3))
        #expect(model.backPageLabel == "ii")

        #expect(!model.goToPage(typed: "999"))
        #expect(!model.goToPage(typed: "chapter"))
        #expect(model.pdfView.currentPage == model.document.page(at: 3))
    }

    // MARK: Copy as Quote

    @Test func quotesCiteTheTitleAndPrintedPage() {
        #expect(Citation.quote("Attention is\nall you  need", title: "Vaswani 2017", page: "245")
            == "\u{201C}Attention is all you need\u{201D} (Vaswani 2017, p. 245)")
        #expect(Citation.quote("Runs over", title: "Paper", firstPage: "12", lastPage: "13")
            == "\u{201C}Runs over\u{201D} (Paper, pp. 12\u{2013}13)")
        #expect(Citation.quote("One page", title: "Paper", firstPage: "xii", lastPage: "xii")
            == "\u{201C}One page\u{201D} (Paper, p. xii)")
    }

    @Test func copyAsQuoteCopiesTheSelectionOrTheHighlight() throws {
        let model = try makeReader(url: try TestFiles.pdf(pages: Self.pages, labels: Self.labels))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SheafTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(!model.copyQuote(to: pasteboard), "Nothing selected or highlighted yet")

        // Selected text, not highlighted.
        try select("Preface", in: model)
        #expect(model.copyQuote(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "\u{201C}Preface\u{201D} (Paper, p. ii)")

        // The highlight just made.
        try select("Chapter one", in: model)
        model.highlightSelection(as: .evidence)
        let record = try #require(model.highlights.first)
        #expect(model.copyQuote(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "\u{201C}Chapter one\u{201D} (Paper, p. 245)")
        #expect(record.quote == "\u{201C}Chapter one\u{201D} (Paper, p. 245)")

        // With nothing selected, the most recent highlight.
        model.selectedHighlightID = nil
        #expect(model.quoteToCopy == model.quote(for: record))
    }

    @Test func markdownCitesLikeCopyAsQuote() throws {
        let model = try makeReader(url: try TestFiles.pdf(pages: Self.pages, labels: Self.labels))
        try select("More text", in: model)
        model.highlightSelection(as: .keyIdea)

        #expect(model.markdownExport().contains("- \u{201C}More text\u{201D} (Paper, p. 246)"))
    }
}
