import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// "Furthest page read" moves on by reading, not by jumping.
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
    private func makeReader(pageCount: Int) throws -> (ReaderModel, LibraryEntry, NSWindow) {
        let document = TestPDF.make(pages: (1...pageCount).map { "Page \($0)" })
        let entry = LibraryEntry(title: "Paper", path: "/tmp/Paper-\(UUID()).pdf", pageCount: pageCount)
        container.mainContext.insert(entry)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: nil, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = model.pdfView
        model.layout = .single
        model.restoreReadingPosition()
        return (model, entry, window)
    }

    private func turnPage(_ model: ReaderModel) async throws {
        let next = model.currentPageIndex + 1
        model.goToNextPage()
        try await waitUntil { model.currentPageIndex == next }
    }

    @Test func turningPagesCountsAsReading() async throws {
        let (model, entry, window) = try makeReader(pageCount: 4)
        defer { window.contentView = nil }

        try await turnPage(model)
        #expect(entry.furthestPageIndex == 1)
        try await turnPage(model)
        try await turnPage(model)

        // Finished: she read her way to the last page.
        #expect(entry.furthestPageIndex == 3)
        #expect(entry.readingStatus == .finished)
    }

    @Test func jumpingToTheEndDoesntFinishThePDF() async throws {
        let (model, entry, window) = try makeReader(pageCount: 6)
        defer { window.contentView = nil }
        try await turnPage(model)

        // Following a link to the references on the last page.
        model.goToPage(number: 6)
        try await waitUntil { model.currentPageIndex == 5 }
        #expect(entry.furthestPageIndex == 1)
        #expect(entry.lastPageIndex == 5, "It still opens where she was")
        #expect(entry.readingStatus == .inProgress)

        // Looking around near where she jumped to doesn't count either.
        model.goToPreviousPage()
        try await waitUntil { model.currentPageIndex == 4 }
        #expect(entry.furthestPageIndex == 1)

        // Back where she was, reading on counts again.
        model.goBack()
        try await waitUntil { model.currentPageIndex == 1 }
        try await turnPage(model)
        #expect(entry.furthestPageIndex == 2)
    }

    @Test func aPageJumpedToCountsOnceItHasBeenOnScreenAWhile() async throws {
        let (model, entry, window) = try makeReader(pageCount: 5)
        defer { window.contentView = nil }
        model.readingDwell = .milliseconds(150)

        model.goToPage(number: 4)
        try await waitUntil { model.currentPageIndex == 3 }
        #expect(entry.furthestPageIndex == 0)

        try await waitUntil { entry.furthestPageIndex == 3 }
        // From there, reading on counts.
        try await turnPage(model)
        #expect(entry.furthestPageIndex == 4)
        #expect(entry.readingStatus == .finished)
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

        #expect(entry.furthestPageIndex == 0)
    }

    @Test func readingStepsAndJumps() {
        var progress = ReadingProgress()
        /// Whether arriving at `page` counts as reading it.
        func reads(_ page: Int, furthest: Int, now: ContinuousClock.Instant = .now) -> Bool {
            progress.arrive(at: page, furthestRead: furthest, now: now)
        }

        progress.start(at: 0)
        #expect(reads(1, furthest: 0))
        // Two pages at once is a spread in the two-page layouts.
        #expect(reads(3, furthest: 1))
        // Dragging the scroll bar to the end, or pressing End.
        #expect(!reads(40, furthest: 3))
        // On from a page she hadn't read.
        #expect(!reads(41, furthest: 3))

        progress.start(at: 3)
        progress.jumpStarting()
        #expect(!reads(4, furthest: 3), "Even a jump to the next page isn't reading")
        // The jump is over: the next change is reading again.
        #expect(reads(5, furthest: 4))

        // A jump that never changed the page doesn't linger.
        let now = ContinuousClock.now
        progress.jumpStarting(now: now)
        #expect(reads(6, furthest: 5, now: now + .seconds(2)))
    }
}
