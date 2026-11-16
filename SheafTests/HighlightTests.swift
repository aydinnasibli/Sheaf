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

    @Test func highlightsAreWrittenIntoTheFileAndFoundAgain() throws {
        let (model, url) = try makeReader(pages: ["Key finding on this page"])
        try select("Key finding", in: model)
        model.highlightSelection(as: .evidence)
        let id = try #require(model.highlights.first?.id)

        model.saveNow()

        let reopened = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: reopened) == [id])
        let annotation = try #require(sheafAnnotations(in: reopened, page: 0).first)
        #expect(annotation.type == "Highlight")
    }

    @Test func notesColorsAndDeletionReachTheFile() throws {
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
        model.saveNow()

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
        #expect(markdown.contains("## Key idea\n\n- \u{201C}Alpha idea\u{201D} (p. 1)"))
        #expect(markdown.contains("## Question\n\n- \u{201C}beta question\u{201D} (p. 1)\n  - Ask the author"))
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
}
