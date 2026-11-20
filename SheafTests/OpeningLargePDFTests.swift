import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Opening PDFs: the pass over the pages in the background, waiting for
/// iCloud Drive, and the reader's second copy of the file.
@MainActor
struct OpeningLargePDFTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    private func highlight(on page: Int, in document: PDFDocument) -> HighlightSnapshot {
        let snapshot = HighlightSnapshot(
            id: UUID(), pageIndex: page, kindRaw: HighlightKind.keyIdea.rawValue, text: "Words", note: "",
            rects: [CGRect(x: 72, y: 700, width: 100, height: 14)], createdAt: .now,
            colorHex: HighlightKind.keyIdea.pageColorHex
        )
        PDFHighlights.add(snapshot, to: document)
        return snapshot
    }

    // MARK: The pass over the pages

    @Test func oneLookAtThePagesFindsLabelsAndHighlights() {
        let document = TestPDF.make(pages: ["a", "b", "c", "d"], labels: "0 << /S /r >> 2 << /S /D /St 245 >>")
        let first = highlight(on: 0, in: document).id
        let second = highlight(on: 3, in: document).id
        let other = UUID()

        let scan = OpeningScan(document)

        #expect(scan.labels == ["i", "ii", "245", "246"])
        #expect(scan.labels == PageLabels.read(from: document))
        #expect(scan.highlightIDs == [first, second])
        #expect(scan.isUpToDate(with: [first, second], removedIDs: []))
        // A highlight the file is missing, or one deleted in Sheaf still in it.
        #expect(!scan.isUpToDate(with: [first, second, other], removedIDs: []))
        #expect(!scan.isUpToDate(with: [first], removedIDs: [second]))
        #expect(scan.isUpToDate(with: [first, second], removedIDs: [other]))
        #expect(OpeningScan(TestPDF.make(pages: ["1", "2"])).labels.isEmpty)
    }

    @Test func theReaderUsesWhatTheBackgroundPassFound() async throws {
        let url = try TestFiles.pdf(pages: ["Preface", "Intro", "Chapter"], labels: "0 << /S /r >> 2 << /S /D /St 245 >>")
        let entry = try #require(store.add(urls: [url]).first)
        let document = OpenDocument(entry: entry, library: store, cloud: FakeCloud())

        document.loadIfNeeded()
        await document.waitUntilLoaded()

        let model = try #require(document.model)
        #expect(model.pageLabels == ["i", "ii", "245"])
        #expect(entry.pageLabels == ["i", "ii", "245"])
        document.close()
    }

    // MARK: iCloud Drive

    @Test func aPDFStillInICloudOpensOnceItsHere() async throws {
        let url = try TestFiles.pdf(pages: ["One", "Two"])
        let entry = try #require(store.add(urls: [url]).first)
        let cloud = FakeCloud()
        cloud.setStatus(.notDownloaded(isDownloading: true), of: url)
        let document = OpenDocument(entry: entry, library: store, cloud: cloud, downloadCheckInterval: .milliseconds(20))

        document.loadIfNeeded()
        try await waitUntil { document.download != nil }
        guard case .downloading = document.phase else {
            Issue.record("It should wait for the download")
            return
        }
        #expect(document.download?.isTransferring == true)
        #expect(cloud.downloadsStarted.count == 1)

        // Slow, or a problem on the way: it keeps waiting, saying what's wrong.
        cloud.setStatus(.failed("The network is offline."), of: url)
        try await waitUntil { document.download?.problem != nil }
        #expect(document.download?.problem == "The network is offline.")
        #expect(DownloadingView.detail(for: document.download, isSlow: false)?.contains("The network is offline.") == true)
        if case .failed = document.phase { Issue.record("A problem downloading shouldn't fail the PDF") }

        cloud.setStatus(.local, of: url)
        await document.waitUntilLoaded()
        #expect(document.model?.pageCount == 2)
        #expect(document.download == nil)
        document.close()
    }

    @Test func cancellingTheDownloadClosesThePDF() async throws {
        let url = try TestFiles.pdf(pages: ["One"])
        let entry = try #require(store.add(urls: [url]).first)
        let cloud = FakeCloud()
        cloud.setStatus(.notDownloaded(isDownloading: false), of: url)
        let document = OpenDocument(entry: entry, library: store, cloud: cloud, downloadCheckInterval: .milliseconds(20))

        document.loadIfNeeded()
        try await waitUntil { document.download != nil }
        #expect(DownloadingView.detail(for: document.download, isSlow: false) == nil)
        #expect(DownloadingView.detail(for: document.download, isSlow: true)?.contains("Waiting for iCloud") == true)
        // What Cancel does (through the workspace, which closes the PDF).
        document.close()
        await document.waitUntilLoaded()

        #expect(document.model == nil)
        if case .failed = document.phase { Issue.record("Cancelling isn't a failure") }
    }

    // MARK: The reader's second copy

    @Test func theBackgroundCopyIsAFileOfItsOwnDeletedOnClose() async throws {
        let url = try TestFiles.pdf(pages: ["One", "Two"])
        let copies = try TestFiles.folder()
        let renderer = PageRenderer(source: .file(url), expectedPageCount: 2, copiesFolder: copies)

        #expect(await renderer.isFileBacked)
        #expect(try FileManager.default.contentsOfDirectory(atPath: copies.path(percentEncoded: false)).count == 1)
        // Saving into the PDF meanwhile doesn't disturb the copy.
        #expect(TestPDF.make(pages: ["Changed"]).write(to: url))
        guard case .image = await renderer.thumbnail(ofPage: 1, fitting: CGSize(width: 60, height: 80), highlights: []) else {
            Issue.record("The copy should still draw page 2")
            return
        }

        await renderer.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: copies.path(percentEncoded: false)).isEmpty)
        guard case .unavailable = await renderer.thumbnail(ofPage: 0, fitting: CGSize(width: 60, height: 80), highlights: []) else {
            Issue.record("Nothing is drawn after closing")
            return
        }
    }

    @Test func closingTheReaderDeletesItsCopy() async throws {
        let url = try TestFiles.pdf(pages: ["One"])
        let entry = store.recordOpen(of: url, document: try #require(PDFDocument(url: url)))
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(
            document: try #require(PDFDocument(url: url)), entry: entry, store: store, fileURL: url, preferences: preferences
        )
        #expect(await model.renderer.isFileBacked)

        model.close()
        let renderer = model.renderer
        try await waitUntilAsync { !(await renderer.isFileBacked) }
    }
}

/// Like `waitUntil`, for a condition that has to be awaited.
@MainActor
func waitUntilAsync(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            struct TimedOut: Error {}
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
