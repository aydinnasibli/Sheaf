import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Highlights saved in a PDF file are never lost: they come back into the
/// library, saving keeps the ones Sheaf doesn't know, and a file that moved
/// is still recognized.
@MainActor
struct HighlightImportTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    private func allEntries() throws -> [LibraryEntry] {
        try container.mainContext.fetch(FetchDescriptor<LibraryEntry>())
    }

    /// Opens an entry as the app does, and waits for the reader.
    private func open(_ entry: LibraryEntry) async throws -> ReaderModel {
        let document = OpenDocument(entry: entry, library: store)
        document.loadIfNeeded()
        try await waitUntil { document.model != nil }
        return try #require(document.model)
    }

    private func highlight(_ text: String, in model: ReaderModel, as kind: HighlightKind = .keyIdea) throws {
        model.pdfView.currentSelection = try #require(model.document.findString(text, withOptions: []).first)
        #expect(model.highlightSelection(as: kind))
    }

    private func idsInFile(_ url: URL) throws -> Set<UUID> {
        PDFHighlights.ids(in: try #require(PDFDocument(url: url)))
    }

    // MARK: Importing

    @Test func highlightsInTheFileJoinANewLibraryEntry() async throws {
        let url = try TestFiles.pdf(pages: ["Imported words stay here", "Second page"])
        let old = try TestFiles.highlight(of: "Imported words", in: url, kind: .question, note: "Ask about this")
        #expect(PDFHighlightWriter.write([old], to: url) == .saved)

        let entry = try #require(store.add(urls: [url]).first)
        #expect(entry.highlights.isEmpty)
        let model = try await open(entry)

        let record = try #require(entry.highlights.first)
        #expect(entry.highlights.count == 1)
        #expect(record.id == old.id)
        #expect(record.kind == .question)
        #expect(record.note == "Ask about this")
        #expect(record.text == "Imported words")
        #expect(record.pageIndex == 0)
        #expect(record.rects.count == old.rects.count)
        #expect(model.highlights.map(\.id) == [old.id])
        #expect(!entry.needsFileSave, "The file already has it")

        // The next highlight leaves the old one in the file.
        try highlight("stay here", in: model)
        await model.saveAndWait()
        #expect(try idsInFile(url) == Set(entry.highlights.map(\.id)))
        #expect(try idsInFile(url).count == 2)
    }

    @Test func highlightsDeletedInSheafDontComeBackFromTheFile() async throws {
        let url = try TestFiles.pdf(pages: ["Delete me later, keep me"])
        let gone = try TestFiles.highlight(of: "Delete me", in: url)
        let kept = try TestFiles.highlight(of: "keep me", in: url)
        #expect(PDFHighlightWriter.write([gone, kept], to: url) == .saved)
        let entry = try #require(store.add(urls: [url]).first)
        _ = try await open(entry)
        #expect(entry.highlights.count == 2)

        // Deleted while the PDF is closed, so the file still has it.
        store.delete(try #require(entry.highlights.first { $0.id == gone.id }))
        #expect(try idsInFile(url) == [gone.id, kept.id])

        let model = try await open(entry)
        #expect(entry.highlights.map(\.id) == [kept.id])
        #expect(!PDFHighlights.ids(in: model.document).contains(gone.id), "Not shown on the page either")

        await model.saveAndWait()
        #expect(try idsInFile(url) == [kept.id])
        #expect(entry.removedHighlightIDs.isEmpty)
        #expect(!entry.needsFileSave)
    }

    @Test func theNearestHighlighterIsPickedForAnImportedColor() {
        #expect(HighlightKind.nearest(toColorHex: 0xFFE066) == .keyIdea)
        #expect(HighlightKind.nearest(toColorHex: 0xFFB0C8) == .question)
        #expect(HighlightKind.nearest(toColorHex: 0x99CCFF) == .definition)
        #expect(HighlightKind.nearest(toColorHex: 0xA8F0B0) == .evidence)
    }

    // MARK: The writer

    @Test func theWriterKeepsSheafHighlightsItWasntToldAboutAndRemovesDeletedOnes() throws {
        let url = try TestFiles.pdf(pages: ["Alpha beta gamma"])
        let alpha = try TestFiles.highlight(of: "Alpha", in: url)
        let beta = try TestFiles.highlight(of: "beta", in: url)
        let gamma = try TestFiles.highlight(of: "gamma", in: url)
        #expect(PDFHighlightWriter.write([alpha, beta, gamma], to: url) == .saved)

        let changed = HighlightSnapshot(
            id: alpha.id, pageIndex: alpha.pageIndex, kindRaw: HighlightKind.evidence.rawValue, text: alpha.text,
            note: "Changed", rects: alpha.rects, createdAt: alpha.createdAt, colorHex: HighlightKind.evidence.pageColorHex
        )
        #expect(PDFHighlightWriter.write([changed], removing: [beta.id], to: url) == .saved)

        let reopened = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: reopened) == [alpha.id, gamma.id])
        let alphaLines = (reopened.page(at: 0)?.annotations ?? []).filter { PDFHighlights.id(of: $0) == alpha.id }
        #expect(alphaLines.count == alpha.rects.count, "Rewritten, not added twice")
        #expect(alphaLines.allSatisfy { $0.contents == "Changed" })
    }

    // MARK: Moved files

    @Test func aMovedFileOpenedAgainFindsItsEntry() throws {
        let url = try TestFiles.pdf(named: "Before.pdf", pages: ["Moving"])
        let entry = try #require(store.add(urls: [url]).first)
        let moved = try TestFiles.folder().appending(path: "After.pdf")
        try FileManager.default.moveItem(at: url, to: moved)

        let again = try #require(store.add(urls: [moved]).first)

        #expect(again.id == entry.id)
        #expect(try allEntries().count == 1)
        #expect(entry.lastKnownPath == LibraryStore.path(of: moved))
        let opened = store.recordOpen(of: moved, document: try #require(PDFDocument(url: moved)))
        #expect(opened.id == entry.id)
    }

    @Test func aCopyOfAFileIsItsOwnEntry() throws {
        let url = try TestFiles.pdf(named: "Original.pdf", pages: ["Copied"])
        let entry = try #require(store.add(urls: [url]).first)
        let copy = try TestFiles.folder().appending(path: "Original.pdf")
        try FileManager.default.copyItem(at: url, to: copy)

        let other = try #require(store.add(urls: [copy]).first)

        #expect(other.id != entry.id)
        #expect(try allEntries().count == 2)
    }

    // MARK: Each highlight's ID is its own

    @Test func aCopyOfAFileGetsHighlightIDsOfItsOwn() async throws {
        let url = try TestFiles.pdf(named: "Original.pdf", pages: ["Shared words stay here"])
        let old = try TestFiles.highlight(of: "Shared words", in: url, kind: .definition, note: "In both files")
        #expect(PDFHighlightWriter.write([old], to: url) == .saved)
        // As Finder's Duplicate, or copying it to another drive, makes.
        let copyURL = try TestFiles.folder().appending(path: "Original copy.pdf")
        try FileManager.default.copyItem(at: url, to: copyURL)
        let original = try #require(store.add(urls: [url]).first)
        let copy = try #require(store.add(urls: [copyURL]).first)

        _ = try await open(original)
        let model = try await open(copy)

        let mine = try #require(original.highlights.first)
        let theirs = try #require(copy.highlights.first)
        #expect(mine.id == old.id)
        #expect(theirs.id != old.id)
        #expect(theirs.note == "In both files")
        #expect(theirs.kind == .definition)
        #expect(theirs.text == "Shared words")
        // Each ID finds its own PDF's highlight.
        #expect(store.highlight(id: old.id)?.entry?.id == original.id)
        #expect(store.highlight(id: theirs.id)?.entry?.id == copy.id)

        // The copy's file gets the new ID at its next save, in place of the old.
        #expect(copy.needsFileSave)
        #expect(copy.removedHighlightIDs == [old.id])
        #expect(PDFHighlights.ids(in: model.document) == [theirs.id])
        await model.saveAndWait()
        #expect(try idsInFile(copyURL) == [theirs.id])
        #expect(try idsInFile(url) == [old.id])
        #expect(copy.removedHighlightIDs.isEmpty)
        #expect(!copy.needsFileSave)

        // Opening it again brings in nothing more.
        _ = try await open(copy)
        #expect(copy.highlights.map(\.id) == [theirs.id])
    }

    @Test func highlightsSharingAnIDGetTheirOwnAsTheLibraryOpens() throws {
        // As copies of one file could leave them before Sheaf checked.
        let original = LibraryEntry(title: "Paper", path: "/Papers/Paper.pdf", pageCount: 1, now: .now - 3600)
        let copy = LibraryEntry(title: "Paper copy", path: "/Backup/Paper.pdf", pageCount: 1)
        container.mainContext.insert(original)
        container.mainContext.insert(copy)
        let rect = CGRect(x: 72, y: 700, width: 100, height: 14)
        let shared = UUID()
        let mine = store.addHighlight(to: original, pageIndex: 0, kind: .keyIdea, text: "Shared", rects: [rect])
        let theirs = store.addHighlight(to: copy, pageIndex: 0, kind: .keyIdea, text: "Shared", rects: [rect])
        let other = store.addHighlight(to: copy, pageIndex: 0, kind: .evidence, text: "Not shared", rects: [rect])
        mine.id = shared
        theirs.id = shared
        original.needsFileSave = false
        copy.needsFileSave = false
        store.save()

        #expect(store.repairDuplicateHighlightIDs() == 1)

        // The PDF added first keeps it.
        #expect(mine.id == shared)
        #expect(theirs.id != shared)
        #expect(other.id != shared && other.text == "Not shared")
        #expect(store.highlight(id: shared)?.entry?.id == original.id)
        #expect(!original.needsFileSave)
        // The copy's file takes the old ID out and writes the new one at its next save.
        #expect(copy.removedHighlightIDs == [shared])
        #expect(copy.needsFileSave)
        #expect(store.repairDuplicateHighlightIDs() == 0)
    }

    @Test func aPDFMovedAfterSavingStillSaves() async throws {
        let url = try TestFiles.pdf(pages: ["First words", "Second words"])
        let entry = try #require(store.add(urls: [url]).first)
        let model = try await open(entry)
        try highlight("First words", in: model)
        await model.saveAndWait()

        // Saving replaced the file; Sheaf must still follow it when it moves.
        let moved = try TestFiles.folder().appending(path: "Renamed.pdf")
        try FileManager.default.moveItem(at: url, to: moved)
        try highlight("Second words", in: model)
        await model.saveAndWait()

        #expect(model.saveError == nil)
        #expect(try idsInFile(moved) == Set(entry.highlights.map(\.id)))
        #expect(try idsInFile(moved).count == 2)
        #expect(entry.lastKnownPath == LibraryStore.path(of: moved))
    }
}
