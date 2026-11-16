import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

@MainActor
struct LibraryStoreTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    private func allItems() throws -> [LibraryEntry] {
        try container.mainContext.fetch(FetchDescriptor<LibraryEntry>())
    }

    /// A real PDF file in this test's temporary folder.
    private func writePDF(named name: String, pages: Int = 3) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SheafTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        let document = TestPDF.make(pages: (1...pages).map { "Page \($0)" })
        #expect(document.write(to: url))
        return url
    }

    @Test func openingAPDFAddsItOnceAndUpdatesLastOpened() throws {
        let url = URL(filePath: "/Users/test/Papers/Sparse Retrieval.pdf")
        let document = TestPDF.make(pages: ["one", "two"])
        let first = Date(timeIntervalSince1970: 1_000_000)

        let item = store.recordOpen(of: url, document: document, now: first)
        let again = store.recordOpen(of: url, document: document, now: first + 3600)

        #expect(try allItems().count == 1)
        #expect(again.id == item.id)
        #expect(item.title == "Sparse Retrieval")
        #expect(item.pageCount == 2)
        #expect(item.addedAt == first)
        #expect(item.lastOpenedAt == first + 3600)
        #expect(item.cover != nil)
    }

    @Test func addingFilesCreatesBookmarksThatResolve() throws {
        let url = try writePDF(named: "Contract.pdf")

        let items = store.add(urls: [url])

        let item = try #require(items.first)
        #expect(item.title == "Contract")
        #expect(item.pageCount == 3)
        #expect(item.bookmark != nil)
        #expect(store.resolveFile(for: item)?.lastPathComponent == "Contract.pdf")
    }

    @Test func addingTheSameFileTwiceKeepsOneItem() throws {
        let url = try writePDF(named: "Notes.pdf")
        store.add(urls: [url])
        store.add(urls: [url])
        #expect(try allItems().count == 1)
    }

    @Test func aMovedFileIsStillFound() throws {
        let url = try writePDF(named: "Before.pdf")
        let item = try #require(store.add(urls: [url]).first)
        let moved = url.deletingLastPathComponent().appending(path: "After.pdf")
        try FileManager.default.moveItem(at: url, to: moved)

        let resolved = store.resolveFile(for: item)

        #expect(resolved?.lastPathComponent == "After.pdf")
        #expect(item.lastKnownPath.hasSuffix("After.pdf"))
    }

    @Test func aDeletedFileIsReportedMissing() throws {
        let url = try writePDF(named: "Gone.pdf")
        let item = try #require(store.add(urls: [url]).first)
        try FileManager.default.removeItem(at: url)

        #expect(store.resolveFile(for: item) == nil)
    }

    @Test func readingProgressAndStatus() {
        let item = LibraryEntry(title: "Book", path: "/book.pdf", pageCount: 10)
        #expect(item.readingStatus == .unread)
        #expect(item.progress == 0.1)

        item.recordPage(4)
        #expect(item.readingStatus == .inProgress)
        #expect(item.progress == 0.5)

        item.recordPage(1)
        #expect(item.lastPageIndex == 1)
        #expect(item.furthestPageIndex == 4)

        item.recordPage(9)
        #expect(item.readingStatus == .finished)

        item.recordPage(50)
        #expect(item.lastPageIndex == 9)
    }

    @Test func collectionsGetColorsInTurnAndKeepPDFsWhenDeleted() throws {
        let research = store.createCollection(named: "Research")
        let work = store.createCollection(named: "  Work  ")
        let untitled = store.createCollection(named: "")
        #expect(research.colorIndex == 0)
        #expect(work.colorIndex == 1)
        #expect(work.name == "Work")
        #expect(untitled.name == "Untitled Collection")

        let item = store.recordOpen(of: URL(filePath: "/a.pdf"), document: TestPDF.make(pages: ["a"]))
        store.move([item], to: research)
        #expect(research.items.count == 1)

        store.delete(research)
        #expect(try allItems().count == 1)
        #expect(item.collection == nil)
    }

    @Test func removingFromLibraryLeavesTheFile() throws {
        let url = try writePDF(named: "Keep me.pdf")
        let item = try #require(store.add(urls: [url]).first)

        store.remove([item])

        #expect(try allItems().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func readerRestoresAndRecordsThePageThroughTheLibrary() {
        let document = TestPDF.make(pages: ["1", "2", "3", "4"])
        let item = store.recordOpen(of: URL(filePath: "/book.pdf"), document: document)
        item.recordPage(2)

        let model = ReaderModel(document: document, libraryItem: item)
        model.restoreReadingPosition()

        #expect(model.pdfView.currentPage.map { document.index(for: $0) } == 2)
    }

    @Test func spaceGroteskIsBundledAndRegistered() {
        let font = Theme.displayFont(20, weight: .bold)
        #expect(font.familyName == "Space Grotesk")
        #expect(font.fontName.contains("Bold"))
    }
}
