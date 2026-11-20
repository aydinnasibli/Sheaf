import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Scanned pages (pictures of text): box highlights, reading their text
/// for search, and the thumbnails drawn in the background.
@MainActor
struct ScannedPageTests {
    private let container: ModelContainer
    private let store: LibraryStore
    /// Text read off scanned pages goes here, never into Sheaf's own storage.
    private let cacheFolder: URL

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        cacheFolder = FileManager.default.temporaryDirectory.appending(path: "SheafRecognizedText-\(UUID().uuidString)")
    }

    /// A reader for a fresh PDF saved in a temporary folder, with a library entry.
    private func makeReader(_ pages: [TestPDF.Page]) throws -> (ReaderModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SheafScanned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Reader.pdf")
        #expect(TestPDF.make(pages).write(to: url))
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences)
        return (model, url)
    }

    private func readScannedPages(_ model: ReaderModel) async throws {
        model.startBackgroundWork(cacheFolder: cacheFolder, after: .zero)
        // Vision may need a moment to load the first time.
        try await waitUntil(timeout: .seconds(60)) {
            model.scannedPages.progress == nil && !model.scannedPages.recognized.isEmpty
        }
    }

    // MARK: Finding scanned pages

    @Test func pagesWithoutSelectableTextAreFound() throws {
        let (model, _) = try makeReader([.text("A typed page"), .scanned("A scanned page")])

        #expect(model.pageHasText(0))
        #expect(!model.pageHasText(1))
    }

    @Test func aHighlighterOnAScannedPageDrawsBoxesAndSaysWhy() throws {
        let (model, _) = try makeReader([.scanned("Scanned first page"), .text("Typed page")])
        let scanned = try #require(model.document.page(at: 0))
        let typed = try #require(model.document.page(at: 1))

        // Off the line of text on the typed page, and on the scanned page's picture of one.
        let blank = CGPoint(x: 300, y: 300)
        let onText = CGPoint(x: 90, y: 704)

        // Nothing picked: text pages select text, and so do scanned ones.
        #expect(model.boxHighlightKind(on: scanned, at: onText, modifiers: []) == nil)
        // Option-drag boxes on scanned pages and off the text; a key idea if no highlighter is picked.
        #expect(model.boxHighlightKind(on: typed, at: blank, modifiers: .option) == .keyIdea)
        #expect(model.boxHighlightKind(on: scanned, at: onText, modifiers: .option) == .keyIdea)
        // On text, Option-drag is PDFKit's: it selects a block of text, as in Preview.
        #expect(model.boxHighlightKind(on: typed, at: onText, modifiers: .option) == nil)

        model.choosePen(.question)
        #expect(model.activePen == .question)
        #expect(model.pageNotice == ReaderModel.scannedPageNotice)
        #expect(model.boxHighlightKind(on: scanned, at: onText, modifiers: []) == .question)
        #expect(model.boxHighlightKind(on: typed, at: blank, modifiers: []) == nil)
        #expect(model.boxHighlightKind(on: typed, at: blank, modifiers: .option) == .question)
        #expect(model.boxHighlightKind(on: typed, at: onText, modifiers: .option) == nil)

        model.dismissPageNotice()
        #expect(model.pageNotice == nil)
    }

    // MARK: Box highlights

    @Test func aBoxHighlightIsAHighlightWithTheBoxAndTheWordsInIt() async throws {
        let (model, _) = try makeReader([.scanned("Mitochondria produce energy")])
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let box = TestPDF.scannedLineRect

        undo.beginUndoGrouping()
        let reading = model.highlightBox(box, onPage: 0, as: .definition)
        undo.endUndoGrouping()

        let record = try #require(model.highlights.first)
        #expect(model.highlights.count == 1)
        #expect(record.kind == .definition)
        #expect(record.pageIndex == 0)
        #expect(record.rects == [box])
        #expect(record.text == ReaderModel.imageAreaText)
        #expect(PDFHighlights.ids(in: model.document) == [record.id])

        await reading?.value
        #expect(record.text.localizedCaseInsensitiveContains("mitochondria"))

        // Undo and Redo bring it back with the words read from the box.
        undo.undo()
        #expect(model.highlights.isEmpty)
        #expect(PDFHighlights.ids(in: model.document).isEmpty)
        undo.redo()
        #expect(model.highlights.map(\.id) == [record.id])
        #expect(model.highlights.first?.text.localizedCaseInsensitiveContains("mitochondria") == true)
    }

    @Test func wordsFoundInABoxReachSpotlight() async throws {
        let spotlight = FakeHighlightIndex()
        store.searchIndex = spotlight
        let (model, _) = try makeReader([.scanned("Mitochondria produce energy")])

        let reading = model.highlightBox(TestPDF.scannedLineRect, onPage: 0, as: .definition)
        let record = try #require(model.highlights.first)
        #expect(spotlight.changes == [.indexed([try #require(SpotlightHighlight(record))])])
        await reading?.value

        // Spotlight first heard of an image area; now it has the words.
        guard case .indexed(let latest) = try #require(spotlight.changes.last), let indexed = latest.first else {
            Issue.record("The words read off the box should be indexed")
            return
        }
        #expect(spotlight.changes.count == 2)
        #expect(indexed.id == record.id)
        #expect(indexed.text.localizedCaseInsensitiveContains("mitochondria"))
        #expect(indexed.text != ReaderModel.imageAreaText)
    }

    @Test func aBoxWithNoWordsIsAnImageArea() async throws {
        let (model, _) = try makeReader([.scanned("Top line only")])

        let reading = model.highlightBox(CGRect(x: 100, y: 100, width: 200, height: 150), onPage: 0, as: .evidence)
        await reading?.value

        #expect(model.highlights.first?.text == ReaderModel.imageAreaText)
    }

    @Test func aBoxOnATypedPageTakesItsText() throws {
        let (model, _) = try makeReader([.text("Boxed words here")])

        let reading = model.highlightBox(CGRect(x: 60, y: 680, width: 300, height: 50), onPage: 0, as: .keyIdea)

        #expect(reading == nil, "Typed pages don't need reading")
        #expect(model.highlights.first?.text == "Boxed words here")
    }

    // MARK: Search

    @Test func searchFindsWordsOnScannedPages() async throws {
        let (model, _) = try makeReader([
            .text("Photosynthesis on a typed page"),
            .scanned("Photosynthesis converts light"),
            .text("Nothing here"),
        ])
        try await readScannedPages(model)
        #expect(model.scannedPages.recognized.keys.sorted() == [1])

        model.searchQuery = "photosynthesis"
        model.search()
        try await waitUntil { !model.isSearching }

        #expect(model.searchResults.map(\.pageIndex) == [0, 1])
        let found = try #require(model.searchResults.last)
        guard case .recognized(let rect, let line) = found.match else {
            Issue.record("The scanned page's match should come from its recognized text")
            return
        }
        #expect(line.localizedCaseInsensitiveContains("photosynthesis"))
        #expect(rect.intersects(TestPDF.scannedLineRect))
        #expect(rect.width < TestPDF.scannedLineRect.width, "Only the matching word is marked")
        #expect(String(model.snippet(for: found).characters).localizedCaseInsensitiveContains("converts light"))
        // PDFKit only highlights the typed page's match.
        #expect(model.pdfView.highlightedSelections?.count == 1)

        model.selectResult(id: found.id)
        #expect(model.selectedResultID == found.id)
        #expect(model.pdfView.currentSelection == nil)
    }

    @Test func matchesOnScannedPagesAreMarkedOverTheWords() async throws {
        let (model, _) = try makeReader([.scanned("Photosynthesis converts light")])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = model.pdfView
        model.layout = .single
        model.zoomToActualSize()
        model.pdfView.scaleFactor = 2
        try await readScannedPages(model)

        model.searchQuery = "photosynthesis"
        model.search()
        try await waitUntil { !model.isSearching }
        model.selectResult(id: 0)
        model.pdfView.layoutSubtreeIfNeeded()

        guard case .recognized(let rect, _) = try #require(model.searchResults.first).match else {
            Issue.record("Expected a match in recognized text")
            return
        }
        let expected = model.pdfView.convert(rect, from: try #require(model.document.page(at: 0)))
        let overlay = try #require(marksViews(in: model.pdfView).first)
        let mark = try #require(overlay.layer?.sublayers?.first)
        let shown = overlay.convert(mark.frame, to: model.pdfView)
        #expect(abs(shown.midX - expected.midX) < 4)
        #expect(abs(shown.midY - expected.midY) < 4)
        #expect(abs(shown.width - expected.width) < 10)
    }

    private func marksViews(in view: NSView) -> [RecognizedMatchOverlay.MarksView] {
        view.subviews.flatMap { ($0 as? RecognizedMatchOverlay.MarksView).map { [$0] } ?? marksViews(in: $0) }
    }

    @Test func textReadOffScannedPagesIsKeptOnDisk() async throws {
        let (model, url) = try makeReader([.scanned("Remember this page")])
        try await readScannedPages(model)
        let first = try #require(model.scannedPages.recognized[0])
        model.close()

        // Saving highlights changes the file's size and date; the page is the same.
        let document = try #require(PDFDocument(url: url))
        let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 50, height: 14), forType: .highlight, withProperties: nil)
        try #require(document.page(at: 0)).addAnnotation(annotation)
        #expect(document.write(to: url))

        let reopened = ReaderModel(document: try #require(PDFDocument(url: url)), entry: model.entry, store: store, fileURL: url)
        let cache = try #require(RecognizedTextCache(fileURL: url, libraryID: model.entry?.id, folder: cacheFolder))
        let info = try #require(await reopened.renderer.pagesWithoutText(in: 0..<1))
        #expect(cache.load(pageCount: 1, current: info) == [first])
    }

    // MARK: Thumbnails

    @Test func thumbnailsAreDrawnOnceAndReused() async throws {
        let (model, _) = try makeReader([.text("One"), .scanned("Two")])

        let first = try #require(await model.thumbnail(forPage: 1))
        let again = try #require(await model.thumbnail(forPage: 1))
        #expect(first === again)
        #expect(model.cachedThumbnail(forPage: 1) === first)
        #expect(await model.renderer.thumbnailsDrawn == 1)
        #expect(first.size == model.thumbnailSize(forPage: 1))

        // A new highlight on the page means a new thumbnail; other pages keep theirs.
        let reading = model.highlightBox(TestPDF.scannedLineRect, onPage: 1, as: .keyIdea)
        #expect(model.cachedThumbnail(forPage: 1) == nil)
        let highlighted = try #require(await model.thumbnail(forPage: 1))
        #expect(highlighted !== first)
        #expect(await model.renderer.thumbnailsDrawn == 2)
        await reading?.value
    }

    @Test func closingThePDFStopsReadingABox() async throws {
        let (model, _) = try makeReader([.scanned("Closed too soon")])

        let reading = model.highlightBox(TestPDF.scannedLineRect, onPage: 0, as: .question)
        model.close()
        await reading?.value

        #expect(model.highlights.first?.text == ReaderModel.imageAreaText)
    }
}
