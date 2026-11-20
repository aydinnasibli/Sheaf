import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Adding PDFs without freezing the window: new files are read, and their
/// covers drawn, away from the main thread; the library's entries are made
/// on it, with the same matching of PDFs already there (moved ones too).
@MainActor
struct BackgroundAddingTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    private func allItems() throws -> [LibraryEntry] {
        try container.mainContext.fetch(FetchDescriptor<LibraryEntry>())
    }

    @Test func newPDFsAreReadAwayFromTheMainThread() async throws {
        let url = try TestFiles.pdf(named: "Cells.pdf", pages: ["one", "two", "three"])
        let cloud = FakeCloud()

        let entry = try #require(await store.addInBackground(urls: [url], cloud: cloud).first)

        #expect(entry.title == "Cells")
        #expect(entry.pageCount == 3)
        #expect(entry.cover != nil)
        #expect(entry.bookmark != nil)
        #expect(store.resolveFile(for: entry)?.lastPathComponent == "Cells.pdf")
        // The file was looked at once, and not from the main thread.
        #expect(cloud.questionsAsked == 1)
        #expect(!cloud.askedOnMainThread)
        #expect(try allItems().count == 1)
    }

    @Test func pdfsAlreadyInTheLibraryArentReadAgain() async throws {
        let url = try TestFiles.pdf(pages: ["one"])
        let first = try #require(store.add(urls: [url]).first)
        let other = try TestFiles.pdf(named: "Other.pdf", pages: ["two"])
        let cloud = FakeCloud()

        let added = await store.addInBackground(urls: [url, other, other], cloud: cloud)

        #expect(added.count == 3)
        #expect(added[0].id == first.id)
        #expect(added[1].id == added[2].id)
        #expect(cloud.questionsAsked == 1, "Only the new file is read, once")
        #expect(try allItems().count == 2)
    }

    @Test func aMovedPDFIsFoundNotAddedTwice() async throws {
        let url = try TestFiles.pdf(named: "Before.pdf", pages: ["one"])
        let item = try #require(store.add(urls: [url]).first)
        let moved = url.deletingLastPathComponent().appending(path: "After.pdf")
        try FileManager.default.moveItem(at: url, to: moved)

        let added = await store.addInBackground(urls: [moved], cloud: FakeCloud())

        #expect(added.map(\.id) == [item.id])
        #expect(item.lastKnownPath.hasSuffix("After.pdf"))
        #expect(try allItems().count == 1)
    }

    @Test func filesThatArentPDFsAreLeftOut() async throws {
        let folder = try TestFiles.folder()
        let fake = folder.appending(path: "Not really.pdf")
        try "plain text".write(to: fake, atomically: true, encoding: .utf8)
        let real = try TestFiles.pdf(pages: ["real"])

        let added = await store.addInBackground(urls: [fake, real], cloud: FakeCloud())

        #expect(added.map(\.title) == ["Paper"])
        #expect(try allItems().count == 1)
    }

    @Test func aPDFNotOnThisMacIsAddedWithoutDownloadingIt() async throws {
        let url = try TestFiles.pdf(named: "In iCloud.pdf", pages: ["one", "two", "three"])
        let cloud = FakeCloud()
        cloud.setStatus(.notDownloaded(isDownloading: false), of: url)

        let entry = try #require(await store.addInBackground(urls: [url], cloud: cloud).first)

        #expect(entry.title == "In iCloud")
        #expect(entry.pageCount == 0)
        #expect(entry.cover == nil)
        #expect(entry.bookmark != nil)
        #expect(cloud.downloadsStarted.isEmpty)

        // Opening it (once it's downloaded) fills in the rest.
        let opened = store.recordOpen(of: url, document: try #require(PDFDocument(url: url)))
        #expect(opened.id == entry.id)
        #expect(opened.pageCount == 3)
        #expect(opened.cover != nil)
    }

    @Test func addingFoldersStillWorksInBatches() async throws {
        let folder = try TestFiles.folder()
        for index in 1...10 {
            #expect(TestPDF.make(pages: ["\(index)"]).write(to: folder.appending(path: "Reading \(index).pdf")))
        }

        let added = await store.addFiles([folder])

        #expect(added.map(\.title) == (1...10).map { "Reading \($0)" })
        #expect(added.allSatisfy { $0.cover != nil && $0.pageCount == 1 })
    }

    @Test func coversAreDrawnOnAnyThread() async throws {
        let png = try #require(await Task.detached {
            LibraryStore.coverImage(for: TestPDF.make(pages: ["Cover page"]))
        }.value)

        let image = try #require(NSBitmapImageRep(data: png))
        // A US Letter page, fitted into 96 × 124.
        #expect(image.pixelsHigh == 124)
        #expect(abs(image.pixelsWide - 96) <= 1)
    }
}
