import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Pages count as read by reading, not by jumping, and a page that counts
/// after a while on screen counts on its own.
@MainActor
struct ReadingProgressTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    /// A reader for a PDF of `pageCount` pages, its page view in a window
    /// (never shown) so pages can be turned, one page at a time.
    private func makeReader(pageCount: Int, layout: ReaderModel.PageLayout = .single) throws -> (ReaderModel, LibraryEntry, NSWindow) {
        let document = TestPDF.make(pages: (1...pageCount).map { "Page \($0)" })
        let entry = LibraryEntry(title: "Paper", path: "/tmp/Paper-\(UUID()).pdf", pageCount: pageCount)
        container.mainContext.insert(entry)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: nil, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = model.pdfView
        model.layout = layout
        model.restoreReadingPosition()
        return (model, entry, window)
    }

    private func turnPage(_ model: ReaderModel) async throws {
        let next = model.currentPageIndex + 1
        model.goToNextPage()
        try await waitUntil { model.currentPageIndex == next }
    }

    @Test func aPDFNeverOpenedHasReadNothing() {
        let entry = LibraryEntry(title: "Paper", path: "/tmp/Two pages.pdf", pageCount: 2)
        #expect(entry.progress == 0)
        #expect(entry.readingStatus == .unread)
    }

    @Test func turningPagesCountsAsReading() async throws {
        let (model, entry, window) = try makeReader(pageCount: 4)
        defer { window.contentView = nil }

        // Reading on from the first page counts it too.
        try await turnPage(model)
        #expect(entry.readPages == [0, 1])
        try await turnPage(model)
        try await turnPage(model)

        // Finished: she read her way to the last page.
        #expect(entry.readPages == [0, 1, 2, 3])
        #expect(entry.readingStatus == .finished)
        #expect(entry.progress == 1)
    }

    @Test func turningSpreadsCountsBothPages() async throws {
        let (model, entry, window) = try makeReader(pageCount: 6, layout: .twoPages)
        defer { window.contentView = nil }
        #expect(model.visiblePageIndices == [0, 1])

        model.goToNextPage()
        try await waitUntil { model.visiblePageIndices == [2, 3] }

        #expect(entry.readPages == [0, 1, 2, 3])
    }

    @Test func jumpingToTheEndDoesntFinishThePDF() async throws {
        let (model, entry, window) = try makeReader(pageCount: 6)
        defer { window.contentView = nil }
        try await turnPage(model)

        // Following a link to the references on the last page.
        model.goToPage(number: 6)
        try await waitUntil { model.currentPageIndex == 5 }
        #expect(entry.readPages == [0, 1])
        #expect(entry.lastPageIndex == 5, "It still opens where she was")
        #expect(entry.readingStatus == .inProgress)

        // Looking around near where she jumped to doesn't count either.
        model.goToPreviousPage()
        try await waitUntil { model.currentPageIndex == 4 }
        #expect(entry.readPages == [0, 1])

        // Back where she was, reading on counts again.
        model.goBack()
        try await waitUntil { model.currentPageIndex == 1 }
        try await turnPage(model)
        #expect(entry.readPages == [0, 1, 2])
    }

    @Test func aPageJumpedToCountsOnItsOwnOnceItHasBeenOnScreenAWhile() async throws {
        let (model, entry, window) = try makeReader(pageCount: 5)
        defer { window.contentView = nil }
        model.readingDwell = .milliseconds(150)

        model.goToPage(number: 4)
        try await waitUntil { model.currentPageIndex == 3 }
        #expect(entry.readPages.isEmpty)

        try await waitUntil { entry.hasRead(3) }
        // That page only: not the pages before it.
        #expect(entry.readPages == [3])

        // From there, reading on counts.
        try await turnPage(model)
        #expect(entry.readPages == [3, 4])
        // On the last page, but she skipped the first three.
        #expect(entry.readingStatus == .inProgress)
        #expect(entry.progress == 0.4)
    }

    @Test func aPageLeftQuicklyDoesntCount() async throws {
        let (model, entry, window) = try makeReader(pageCount: 5)
        defer { window.contentView = nil }
        model.readingDwell = .milliseconds(300)

        model.goToPage(number: 5)
        try await waitUntil { model.currentPageIndex == 4 }
        model.goBack()
        try await waitUntil { model.currentPageIndex == 0 }
        try await Task.sleep(for: .milliseconds(500))

        #expect(!entry.hasRead(4))
        #expect(entry.readingStatus != .finished)
    }

    @Test func readingStepsAndJumps() {
        var progress = ReadingProgress()
        var read = Set<Int>()
        /// The pages that arriving at `pages` counts as read.
        func arrive(_ pages: [Int], now: ContinuousClock.Instant = .now) -> [Int] {
            let counted = progress.arrive(at: pages, hasRead: { read.contains($0) }, now: now)
            read.formUnion(counted)
            return counted
        }

        progress.start(at: [0])
        // Reading on from the start of the PDF counts both pages.
        #expect(arrive([1]) == [0, 1])
        // Two pages at once is a spread in the two-page layouts.
        #expect(arrive([3]) == [1, 2, 3])
        // Dragging the scroll bar to the end, or pressing End.
        #expect(arrive([40]).isEmpty)
        // On from a page she hadn't read.
        #expect(arrive([41]).isEmpty)
        // Back a page isn't reading on.
        #expect(arrive([40]).isEmpty)

        progress.start(at: [3])
        progress.jumpStarting()
        #expect(arrive([4]).isEmpty, "Even a jump to the next page isn't reading")
        // The jump is over: once the page it landed on counts (after a
        // while on screen), reading on from it counts again.
        read.insert(4)
        #expect(arrive([5]) == [4, 5])

        // A jump that never changed the page doesn't linger.
        let now = ContinuousClock.now
        progress.jumpStarting(now: now)
        #expect(arrive([6], now: now + .seconds(2)) == [5, 6])

        // Spreads: the pages of the first one count too.
        read = []
        progress.start(at: [0, 1])
        #expect(arrive([2, 3]) == [0, 1, 2, 3])
        // With book spreads the cover is on its own.
        read = []
        progress.start(at: [0])
        #expect(arrive([1, 2]) == [0, 1, 2])
        #expect(arrive([3, 4]) == [1, 2, 3, 4])
    }
}
