import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// The library's search of PDF text: scanned pages, printed page labels,
/// PDFs in iCloud Drive and text saved by older versions. Each test keeps
/// its index and the reader's text in folders of its own, never Sheaf's.
@MainActor
struct LibraryTextSearchTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let folder: URL
    private let indexFolder: URL
    private let recognizedFolder: URL

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        folder = try TestFiles.folder()
        indexFolder = folder.appending(path: "Text Index")
        recognizedFolder = folder.appending(path: "Recognized Text")
    }

    private func makeIndexer(cloud: FakeCloud = FakeCloud()) -> TextIndexer {
        let indexer = TextIndexer(
            index: TextIndex(directory: indexFolder), cloud: cloud,
            recognizedTextFolder: recognizedFolder, recheckInterval: .seconds(3600)
        )
        indexer.start(library: store, catchingUpAfter: nil)
        return indexer
    }

    private func source(for entry: LibraryEntry) -> TextIndexer.Source {
        TextIndexer.Source(id: entry.id, bookmark: entry.bookmark, path: entry.lastKnownPath)
    }

    // MARK: Scanned pages

    @Test func wordsReadOffScannedPagesAreFoundInTheLibrary() async throws {
        let url = folder.appending(path: "Course reader.pdf")
        #expect(TestPDF.make([.text("Cells and membranes"), .scanned("Photosynthesis converts light"), .text("Summary")]).write(to: url))
        let entry = try #require(store.add(urls: [url]).first)
        let cloud = FakeCloud()
        let indexer = makeIndexer(cloud: cloud)

        // Before the reader has read the scanned page, only typed text is found.
        indexer.index([entry])
        await indexer.finishIndexing()
        #expect(await indexer.search("photosynthesis", in: [entry]).isEmpty)
        #expect(await indexer.search("membranes", in: [entry]).first?.pages.map(\.index) == [0])

        // The reader reads the scanned page, keeping the words in this test's folder.
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(
            document: try #require(PDFDocument(url: url)), entry: entry, store: store, fileURL: url, preferences: preferences
        )
        model.startBackgroundWork(cacheFolder: recognizedFolder, after: .zero)
        try await waitUntil(timeout: .seconds(60)) {
            model.scannedPages.progress == nil && !model.scannedPages.recognized.isEmpty
        }
        model.close()

        // The library takes the words in, without reading the PDF again.
        indexer.index([entry])
        await indexer.finishIndexing()
        let match = try #require(await indexer.search("photosynthesis", in: [entry]).first)
        #expect(match.pages.map(\.index) == [1])
        #expect(match.pages[0].snippet.localizedCaseInsensitiveContains("converts light"))
        #expect(indexer.generation == 2)
        // Nothing new since: nothing is read.
        #expect(await TextIndexer.update(source(for: entry), in: indexer.index, cloud: cloud, recognizedTextFolder: recognizedFolder) == .unchanged)

        // An index starting over (the PDF changed, say) also has the words.
        let fresh = TextIndex(directory: folder.appending(path: "Another Index"))
        #expect(await TextIndexer.update(source(for: entry), in: fresh, cloud: cloud, recognizedTextFolder: recognizedFolder) == .read)
        #expect(await fresh.search("photosynthesis", in: [entry.id]).first?.pages.map(\.index) == [1])
        #expect(await fresh.search("membranes", in: [entry.id]).first?.pages.map(\.index) == [0])
    }

    @Test func pagesWithoutTextAreRememberedWithTheirFingerprints() throws {
        let document = TestPDF.make([.text("Typed"), .scanned("Scanned"), .text("Typed again")])

        let contents = TextIndex.read(document)

        #expect(contents.pages == ["Typed", "", "Typed again"])
        #expect(contents.scannedPages.map(\.index) == [1])
        let page = try #require(document.page(at: 1))
        #expect(contents.scannedPages.first?.fingerprint == PageText.fingerprint(of: page))
    }

    // MARK: Printed page labels

    @Test func matchesShowThePagesAsPrinted() async throws {
        let url = try TestFiles.pdf(
            pages: ["Preface words", "Intro words", "Chapter one quantum", "More quantum"],
            labels: "0 << /S /r >> 2 << /S /D /St 245 >>"
        )
        let entry = try #require(store.add(urls: [url]).first)
        let indexer = makeIndexer()
        indexer.index([entry])
        await indexer.finishIndexing()

        let match = try #require(await indexer.search("quantum", in: [entry]).first)

        #expect(match.pages.map(\.index) == [2, 3])
        #expect(match.pages.map(\.label) == ["245", "246"])
        #expect(TextMatchesSection.pageLabel(of: match.pages[0], in: entry) == "245")
        let line = String(TextMatchesSection.line(for: match.pages[0], in: entry, query: "quantum").characters)
        #expect(line.hasPrefix("p. 245 \u{00B7} "))
        #expect(await indexer.search("preface", in: [entry]).first?.pages.first?.label == "i")
    }

    @Test func matchesFallBackToTheLabelsTheLibraryRemembers() {
        let entry = LibraryEntry(title: "Book", path: "/Book.pdf", pageCount: 4)
        // Saving highlights into a PDF loses its labels, so the index may have none.
        let page = TextIndex.Match.Page(index: 1, snippet: "Intro words")

        #expect(TextMatchesSection.pageLabel(of: page, in: entry) == "2")
        entry.pageLabels = ["i", "ii", "245", "246"]
        #expect(TextMatchesSection.pageLabel(of: page, in: entry) == "ii")
        #expect(String(TextMatchesSection.line(for: page, in: entry, query: "intro").characters).hasPrefix("p. ii"))
    }

    // MARK: iCloud Drive

    @Test func pdfsNotOnThisMacAreLeftAloneUntilTheyAre() async throws {
        let url = try TestFiles.pdf(pages: ["Entropy always increases"])
        let entry = try #require(store.add(urls: [url]).first)
        let cloud = FakeCloud()
        cloud.setStatus(.notDownloaded(isDownloading: false), of: url)
        let indexer = makeIndexer(cloud: cloud)

        indexer.index([entry])
        await indexer.finishIndexing()

        #expect(await indexer.index.pages(for: entry.id) == nil)
        #expect(Array(indexer.waitingForDownload.keys) == [entry.id])
        #expect(cloud.downloadsStarted.isEmpty)
        #expect(indexer.generation == 0)

        // Downloaded since (she opened it, or Finder did): the next look reads it.
        cloud.setStatus(.local, of: url)
        indexer.recheckWaiting()
        await indexer.finishIndexing()

        #expect(await indexer.search("entropy", in: [entry]).first?.pages.map(\.index) == [0])
        #expect(indexer.waitingForDownload.isEmpty)
        #expect(cloud.downloadsStarted.isEmpty)
    }

    @Test func aFileThatIsntDownloadedIsNeverRead() async throws {
        let url = try TestFiles.pdf(pages: ["Not here yet"])
        let entry = try #require(store.add(urls: [url]).first)
        let index = TextIndex(directory: indexFolder)
        let cloud = FakeCloud()

        cloud.setStatus(.notDownloaded(isDownloading: true), of: url)
        #expect(await TextIndexer.update(source(for: entry), in: index, cloud: cloud) == .notDownloaded)
        cloud.setStatus(.failed("The network is offline."), of: url)
        #expect(await TextIndexer.update(source(for: entry), in: index, cloud: cloud) == .notDownloaded)

        #expect(await index.pages(for: entry.id) == nil)
        #expect(cloud.downloadsStarted.isEmpty)
    }

    // MARK: Saved text

    @Test func savedTextIsSearchedFromDisk() async throws {
        let id = UUID()
        let stamp = TextIndex.Stamp(size: 10, modifiedAt: .now)
        await TextIndex(directory: indexFolder).store(
            TextIndex.Contents(pages: ["R\u{00E9}sum\u{00E9} of the week", "Nothing"], labels: ["7", "8"]), for: id, stamp: stamp
        )

        // As after relaunching: nothing in memory, the file is read as it's searched.
        let reopened = TextIndex(directory: indexFolder)
        let match = try #require(await reopened.search("RESUME", in: [id]).first)

        #expect(match.pages.map(\.index) == [0])
        #expect(match.pages[0].snippet == "R\u{00E9}sum\u{00E9} of the week")
        #expect(match.pages[0].label == "7")
        #expect(await reopened.isCurrent(id, stamp: stamp))
        #expect(await reopened.pages(for: id) == ["R\u{00E9}sum\u{00E9} of the week", "Nothing"])
    }

    @Test func textSavedByAnOlderSheafIsFoundUntilItsReadAgain() async throws {
        struct Version1: Encodable {
            var version = 1
            var fileSize: Int
            var modifiedAt: Date
            var pages: [String]
        }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(at: indexFolder, withIntermediateDirectories: true)
        let old = indexFolder.appending(path: "\(id.uuidString).json")
        try JSONEncoder().encode(Version1(fileSize: 10, modifiedAt: date, pages: ["Old saved words"])).write(to: old)

        let index = TextIndex(directory: indexFolder)

        #expect(await index.search("saved words", in: [id]).first?.pages.map(\.index) == [0])
        // It has no page labels or scanned pages, so it's read again when its turn comes.
        #expect(!(await index.isCurrent(id, stamp: .init(size: 10, modifiedAt: date))))
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
    }
}
