import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// The text index behind the library's search of PDF text. Each test uses
/// its own index folder in the temporary folder, never Sheaf's real one.
@MainActor
struct TextIndexTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let folder: URL
    private let indexFolder: URL

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        folder = FileManager.default.temporaryDirectory.appending(path: "SheafTextIndex-\(UUID().uuidString)")
        indexFolder = folder.appending(path: "Text Index")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func writePDF(named name: String = "Paper.pdf", pages: [String]) throws -> URL {
        let url = folder.appending(path: name)
        #expect(TestPDF.make(pages: pages).write(to: url))
        return url
    }

    private func makeIndexer() -> TextIndexer {
        let indexer = TextIndexer(index: TextIndex(directory: indexFolder))
        indexer.start(library: store, catchingUpAfter: nil)
        return indexer
    }

    @Test func findsAWordOnPageThree() async throws {
        let url = try writePDF(pages: ["Cells and membranes", "Respiration in mitochondria", "Photosynthesis turns light into sugar", "Summary"])
        let entry = try #require(store.add(urls: [url]).first)
        let indexer = makeIndexer()

        indexer.index([entry])
        await indexer.finishIndexing()

        let match = try #require(await indexer.search("photosynthesis", in: [entry]).first)
        #expect(match.entryID == entry.id)
        #expect(match.pages.map(\.index) == [2])
        #expect(match.pageCount == 1)
        #expect(match.pages[0].snippet == "Photosynthesis turns light into sugar")
        #expect(await indexer.search("LIGHT into", in: [entry]).first?.pages.first?.index == 2)
        #expect(await indexer.search("chlorophyll", in: [entry]).isEmpty)
        #expect(indexer.generation == 1)

        // Saved on disk: a new index finds the text without reading the PDF.
        let reopened = TextIndex(directory: indexFolder)
        #expect(await reopened.pages(for: entry.id)?[2] == "Photosynthesis turns light into sugar")
    }

    @Test func goesStaleWhenTheFileChanges() async throws {
        let url = try writePDF(pages: ["One", "Two", "Old words here"])
        let entry = try #require(store.add(urls: [url]).first)
        let index = TextIndex(directory: indexFolder)
        let source = TextIndexer.Source(id: entry.id, bookmark: entry.bookmark, path: entry.lastKnownPath)

        #expect(await TextIndexer.update(source, in: index))
        let stamp = try #require(TextIndex.Stamp(of: url))
        #expect(await index.isCurrent(entry.id, stamp: stamp))
        // Unchanged, the PDF isn't read again.
        #expect(!(await TextIndexer.update(source, in: index)))

        // The PDF is replaced by a new version.
        #expect(TestPDF.make(pages: ["One", "Two", "New words instead"]).write(to: url))
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: url.path)
        let changed = try #require(TextIndex.Stamp(of: url))
        #expect(changed != stamp)
        #expect(!(await index.isCurrent(entry.id, stamp: changed)))

        #expect(await TextIndexer.update(source, in: index))
        #expect(await index.search("new words", in: [entry.id]).first?.pages.first?.index == 2)
        #expect(await index.search("old words", in: [entry.id]).isEmpty)
    }

    @Test func searchIgnoresCaseAndAccentsAndSkipsOneLetter() async {
        let index = TextIndex(directory: indexFolder)
        let id = UUID()
        await index.store(["Le caf\u{00E9} du coin", "Nothing", "CAFE again"], for: id, stamp: .init(size: 1, modifiedAt: .now))

        let match = await index.search("Cafe", in: [id]).first
        #expect(match?.pages.map(\.index) == [0, 2])
        #expect(match?.pageCount == 2)
        #expect(await index.search("e", in: [id]).isEmpty)
    }

    @Test func showsAFewPagesAndCountsTheRest() async {
        let index = TextIndex(directory: indexFolder)
        let id = UUID()
        await index.store((1...6).map { "Theorem \($0) holds" }, for: id, stamp: .init(size: 1, modifiedAt: .now))

        let match = await index.search("theorem", in: [id]).first
        #expect(match?.pages.map(\.index) == [0, 1, 2])
        #expect(match?.pageCount == 6)
    }

    @Test func pageTextIsMadeEasyToSearch() {
        #expect(TextIndex.normalize("The  quick\nbrown \t fox\n\n") == "The quick brown fox")
        #expect(TextIndex.normalize("a repre-\nsentation of") == "a representation of")
        #expect(TextIndex.normalize("Figure 3-\nB") == "Figure 3- B")
        #expect(TextIndex.normalize("e\u{FB03}cient") == "efficient")
        #expect(TextIndex.normalize("soft\u{00AD}ware") == "software")
    }

    @Test func snippetsStartAndEndOnWholeWords() throws {
        let text = String(repeating: "alpha beta gamma ", count: 10) + "TARGET" + String(repeating: " delta epsilon", count: 20)
        let range = try #require(text.range(of: "TARGET"))

        let snippet = TextIndex.snippet(in: text, around: range)

        #expect(snippet.hasPrefix("\u{2026}"))
        #expect(snippet.hasSuffix("\u{2026}"))
        #expect(snippet.contains("TARGET"))
        let words = snippet.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2026}")).split(separator: " ")
        let known: Set<Substring> = ["alpha", "beta", "gamma", "TARGET", "delta", "epsilon"]
        #expect(words.allSatisfy(known.contains))
    }

    @Test func forgetsPDFsRemovedFromTheLibrary() async throws {
        let kept = try #require(store.add(urls: [try writePDF(named: "Kept.pdf", pages: ["kept text"])]).first)
        let removed = try #require(store.add(urls: [try writePDF(named: "Removed.pdf", pages: ["removed text"])]).first)
        let removedID = removed.id
        let indexer = makeIndexer()
        indexer.index([kept, removed])
        await indexer.finishIndexing()

        store.remove([removed])
        await indexer.catchUp()
        await indexer.finishIndexing()

        let reopened = TextIndex(directory: indexFolder)
        #expect(await reopened.pages(for: kept.id) != nil)
        #expect(await reopened.pages(for: removedID) == nil)
    }

    @Test func aMatchOpensThePDFAtItsPage() async throws {
        let entry = try #require(store.add(urls: [try writePDF(pages: ["1", "2", "3", "4"])]).first)
        let preferences = try #require(UserDefaults(suiteName: "SheafTextIndexTests.\(UUID().uuidString)"))
        let workspace = Workspace(library: store, preferences: preferences)

        workspace.open(entry, atPage: 2)

        #expect(workspace.selectedDocument?.id == entry.id)
        #expect(workspace.selectedDocument?.pendingPageIndex == 2)
        // PDFs load in the background; let it finish before this test's library goes away.
        await workspace.selectedDocument?.waitUntilLoaded()
    }
}
