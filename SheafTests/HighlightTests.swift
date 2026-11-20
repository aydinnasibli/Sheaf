import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

@MainActor
struct HighlightTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    /// A reader for a fresh PDF saved in a temporary folder, with a library entry.
    private func makeReader(pages: [String]) throws -> (ReaderModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SheafHighlights-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Paper.pdf")
        #expect(TestPDF.make(pages: pages).write(to: url))
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        // A throwaway preferences domain, so tests never change the app's saved layout.
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences)
        return (model, url)
    }

    private func select(_ text: String, in model: ReaderModel) throws {
        let selection = try #require(model.document.findString(text, withOptions: [.caseInsensitive]).first)
        model.pdfView.currentSelection = selection
    }

    private func sheafAnnotations(in document: PDFDocument, page: Int) -> [PDFAnnotation] {
        (document.page(at: page)?.annotations ?? []).filter { PDFHighlights.id(of: $0) != nil }
    }

    @Test func highlightingASelectionSavesItInBothPlaces() throws {
        let (model, _) = try makeReader(pages: ["The quick brown fox jumps", "Second page"])
        try select("brown fox", in: model)

        #expect(model.highlightSelection(as: .question))

        let record = try #require(model.highlights.first)
        #expect(model.highlights.count == 1)
        #expect(record.kind == .question)
        #expect(record.text == "brown fox")
        #expect(record.pageIndex == 0)
        #expect(record.entry?.highlightCounts == [0, 1, 0, 0])

        let annotations = sheafAnnotations(in: model.document, page: 0)
        #expect(annotations.count == 1)
        #expect(annotations.first?.type == "Highlight")
        #expect(PDFHighlights.id(of: annotations[0]) == record.id)
        #expect(model.pdfView.currentSelection == nil)
    }

    @Test func nothingSelectedMeansNoHighlight() throws {
        let (model, _) = try makeReader(pages: ["Some text"])
        #expect(!model.highlightSelection(as: .keyIdea))
        #expect(model.highlights.isEmpty)
    }

    @Test func choosingAPenWithoutASelectionTogglesHighlightMode() throws {
        let (model, _) = try makeReader(pages: ["Some text"])
        model.choosePen(.definition)
        #expect(model.activePen == .definition)
        model.choosePen(.definition)
        #expect(model.activePen == nil)
    }

    @Test func highlightsAreWrittenIntoTheFileAndFoundAgain() async throws {
        let (model, url) = try makeReader(pages: ["Key finding on this page"])
        try select("Key finding", in: model)
        model.highlightSelection(as: .evidence)
        let id = try #require(model.highlights.first?.id)

        await model.saveAndWait()

        let reopened = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: reopened) == [id])
        let annotation = try #require(sheafAnnotations(in: reopened, page: 0).first)
        #expect(annotation.type == "Highlight")
    }

    @Test func notesColorsAndDeletionReachTheFile() async throws {
        let (model, url) = try makeReader(pages: ["A definition worth keeping"])
        try select("definition", in: model)
        model.highlightSelection(as: .keyIdea)
        let record = try #require(model.highlights.first)

        model.setNote("Use in chapter 2", for: record)
        model.setKind(.definition, for: record)
        #expect(record.note == "Use in chapter 2")
        #expect(record.kind == .definition)
        #expect(sheafAnnotations(in: model.document, page: 0).first?.contents == "Use in chapter 2")

        model.delete(record)
        await model.saveAndWait()

        #expect(model.highlights.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<HighlightRecord>()).isEmpty)
        let reopened = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: reopened).isEmpty)
    }

    @Test func missingHighlightsAreRestoredFromTheIndex() throws {
        let (model, url) = try makeReader(pages: ["Restore me please"])
        try select("Restore me", in: model)
        model.highlightSelection(as: .keyIdea)
        // The file never got the highlight (no save), so reopening must re-add it.
        let fresh = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: fresh).isEmpty)

        let reopened = ReaderModel(document: fresh, entry: model.entry, store: store, fileURL: url)

        #expect(PDFHighlights.ids(in: reopened.document).count == 1)
    }

    @Test func markersAndGroupsFollowThePage() throws {
        let (model, _) = try makeReader(pages: ["First page text", "Second page text"])
        try select("Second page", in: model)
        model.highlightSelection(as: .question)

        #expect(model.markers(onPage: 0).isEmpty)
        let marker = try #require(model.markers(onPage: 1).first)
        #expect(marker.kind == .question)
        #expect(marker.position > 0 && marker.position < 0.5)
        #expect(model.highlightGroups.map(\.page) == [1])

        model.panelFilter = [.keyIdea]
        #expect(model.highlightGroups.isEmpty)
    }

    @Test func markdownExportGroupsByMeaning() throws {
        let (model, _) = try makeReader(pages: ["Alpha idea and beta question"])
        try select("Alpha idea", in: model)
        model.highlightSelection(as: .keyIdea)
        try select("beta question", in: model)
        model.highlightSelection(as: .question)
        model.setNote("Ask the author", for: try #require(model.highlights.first { $0.kind == .question }))

        let markdown = model.markdownExport()

        #expect(markdown.hasPrefix("# Paper"))
        #expect(markdown.contains("## Key idea\n\n- \u{201C}Alpha idea\u{201D} (Paper, p. 1)"))
        #expect(markdown.contains("## Question\n\n- \u{201C}beta question\u{201D} (Paper, p. 1)\n  - Ask the author"))
        #expect(!markdown.contains("## Definition"))
    }

    @Test func twoPageLayoutShowsBothPageNumbers() throws {
        let (model, _) = try makeReader(pages: ["1", "2", "3"])
        #expect(model.pageLabel == "1")
        model.layout = .twoPages
        #expect(model.pdfView.displayMode == .twoUp)
        #expect(model.pageLabel == "1\u{2013}2")
        model.layout = .single
        #expect(model.pdfView.displayMode == .singlePage)
    }

    @Test func bookSpreadsShowTheCoverOnItsOwn() throws {
        let (model, _) = try makeReader(pages: ["1", "2", "3", "4"])
        model.layout = .twoPageScroll
        #expect(model.pdfView.displayMode == .twoUpContinuous)
        #expect(model.pageLabel == "1\u{2013}2")

        model.showsBookSpreads = true
        #expect(model.pdfView.displaysAsBook)
        #expect(model.pageLabel == "1")
        #expect(model.canGoToNextPage)
        #expect(!model.canGoToPreviousPage)
    }

    @Test func bookmarksAreKeptInTheLibraryAndCanBeUndone() throws {
        let (model, _) = try makeReader(pages: ["1", "2", "3"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        undo.beginUndoGrouping()
        model.toggleBookmark(page: 2)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        model.toggleBookmark(page: 0)
        undo.endUndoGrouping()
        #expect(model.bookmarks == [0, 2])
        #expect(model.entry?.bookmarkedPages == [0, 2])

        undo.undo()
        #expect(model.bookmarks == [2])

        undo.beginUndoGrouping()
        model.toggleBookmark(page: 2)
        undo.endUndoGrouping()
        #expect(model.bookmarks.isEmpty)
    }

    @Test func printingWithoutHighlightsLeavesThemOutOfACopy() throws {
        let (model, _) = try makeReader(pages: ["Alpha idea here"])
        try select("Alpha idea", in: model)
        model.highlightSelection(as: .keyIdea)

        let withHighlights = sheafAnnotations(in: model.documentForPrinting(includingHighlights: true), page: 0)
        #expect(!withHighlights.isEmpty)
        #expect(withHighlights.allSatisfy { $0.shouldPrint })
        #expect(sheafAnnotations(in: model.documentForPrinting(includingHighlights: false), page: 0).isEmpty)
        // The PDF on screen keeps its highlights.
        #expect(!sheafAnnotations(in: model.document, page: 0).isEmpty)
    }

    @Test func theFitModeIsRememberedForTheNextPDF() throws {
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let first = ReaderModel(document: TestPDF.make(pages: ["One"]), entry: nil, store: nil, fileURL: nil, preferences: preferences)
        // Scrolling pages start out filling the width, as before.
        #expect(first.layout == .scroll)
        #expect(first.zoomMode == .fitWidth)

        first.zoomToFit()
        #expect(first.zoomMode == .fitPage)
        first.zoomIn()
        #expect(first.zoomMode == .custom)

        // Zooming in by hand isn't remembered; the last fit mode is.
        let next = ReaderModel(document: TestPDF.make(pages: ["Two"]), entry: nil, store: nil, fileURL: nil, preferences: preferences)
        #expect(next.zoomMode == .fitPage)
    }

    // MARK: Undo

    @Test func undoAndRedoAHighlight() throws {
        let (model, _) = try makeReader(pages: ["Undo this highlight"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo

        try select("this highlight", in: model)
        undo.beginUndoGrouping()
        model.highlightSelection(as: .keyIdea)
        undo.endUndoGrouping()
        let id = try #require(model.highlights.first?.id)
        #expect(undo.undoActionName == "Highlight")

        undo.undo()
        #expect(model.highlights.isEmpty)
        #expect(PDFHighlights.ids(in: model.document).isEmpty)

        undo.redo()
        #expect(model.highlights.map(\.id) == [id])
        #expect(PDFHighlights.ids(in: model.document) == [id])
    }

    @Test func undoDeleteNoteAndColorChanges() throws {
        let (model, _) = try makeReader(pages: ["Keep this one safe"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        try select("Keep this", in: model)
        // This test's undo manager needs explicit groups (the app's groups
        // each user action automatically).
        undo.beginUndoGrouping()
        model.highlightSelection(as: .keyIdea)
        undo.endUndoGrouping()
        let record = try #require(model.highlights.first)
        let id = record.id

        undo.beginUndoGrouping()
        model.setNote("first note", for: record)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        model.setKind(.evidence, for: record)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        model.delete(record)
        undo.endUndoGrouping()
        #expect(model.highlights.isEmpty)

        undo.undo() // delete
        let restored = try #require(model.highlight(id: id))
        #expect(restored.kind == .evidence)
        #expect(restored.note == "first note")

        undo.undo() // color
        #expect(model.highlight(id: id)?.kind == .keyIdea)
        undo.undo() // note
        #expect(model.highlight(id: id)?.note == "")
    }

    // MARK: Saving

    @Test func savingRunsInTheBackgroundAndKeepsOtherAppsHighlights() async throws {
        let (model, url) = try makeReader(pages: ["Sheaf text", "More text"])
        // A highlight made by another app, already in the file.
        let other = try #require(PDFDocument(url: url))
        let foreign = PDFAnnotation(bounds: CGRect(x: 72, y: 690, width: 50, height: 14), forType: .highlight, withProperties: nil)
        try #require(other.page(at: 1)).addAnnotation(foreign)
        #expect(other.write(to: url))

        try select("Sheaf text", in: model)
        model.highlightSelection(as: .question)
        await model.saveAndWait()

        let reopened = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: reopened).count == 1)
        #expect(reopened.page(at: 1)?.annotations.contains { $0.type == "Highlight" } == true)
        #expect(model.saveError == nil)
    }

    @Test func signedPDFsAreNeverRewritten() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Signed-\(UUID().uuidString).pdf")
        let document = TestPDF.make(pages: ["Contract text"])
        let field = PDFAnnotation(bounds: CGRect(x: 72, y: 100, width: 200, height: 40), forType: .widget, withProperties: nil)
        field.widgetFieldType = .signature
        try #require(document.page(at: 0)).addAnnotation(field)
        #expect(document.write(to: url))
        let before = try Data(contentsOf: url)

        let snapshot = HighlightSnapshot(
            id: UUID(), pageIndex: 0, kindRaw: 1, text: "Contract", note: "",
            rects: [CGRect(x: 72, y: 700, width: 60, height: 14)], createdAt: .now, colorHex: 0xFFE066
        )
        let outcome = PDFHighlightWriter.write([snapshot], to: url)

        #expect(outcome == .signed)
        #expect(try Data(contentsOf: url) == before)
    }
}
