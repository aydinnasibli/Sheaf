import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Saving into PDF files can't break them or lose highlights, and the
/// library is backed up.
@MainActor
struct FileSafetyTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    /// A reader for a new PDF file with a library entry, as in the app.
    private func makeReader(store: LibraryStore? = nil, pages: [String]) throws -> (ReaderModel, URL) {
        let store = store ?? self.store
        let url = try TestFiles.pdf(pages: pages)
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        return (ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences), url)
    }

    private func highlight(_ text: String, in model: ReaderModel) throws {
        model.pdfView.currentSelection = try #require(model.document.findString(text, withOptions: []).first)
        #expect(model.highlightSelection(as: .keyIdea))
    }

    private func idsInFile(_ url: URL) throws -> Set<UUID> {
        PDFHighlights.ids(in: try #require(PDFDocument(url: url)))
    }

    // MARK: Saving

    @Test func theNewFileIsCheckedBeforeItReplacesTheOldOne() throws {
        let document = TestPDF.make(pages: ["One", "Two"])
        let highlight = HighlightSnapshot(
            id: UUID(), pageIndex: 1, kindRaw: 1, text: "Two", note: "",
            rects: [CGRect(x: 72, y: 700, width: 30, height: 14)], createdAt: .now, colorHex: 0xFFE066
        )
        let plain = try #require(document.dataRepresentation())
        #expect(PDFHighlightWriter.isComplete(plain, pageCount: 2, highlights: []))
        #expect(!PDFHighlightWriter.isComplete(Data("not a PDF".utf8), pageCount: 2, highlights: []))
        #expect(!PDFHighlightWriter.isComplete(plain, pageCount: 3, highlights: []), "A page went missing")
        #expect(!PDFHighlightWriter.isComplete(plain, pageCount: 2, highlights: [highlight]), "The highlight went missing")

        for annotation in PDFHighlightWriter.makeAnnotations(for: highlight) {
            try #require(document.page(at: 1)).addAnnotation(annotation)
        }
        #expect(PDFHighlightWriter.isComplete(try #require(document.dataRepresentation()), pageCount: 2, highlights: [highlight]))
    }

    @Test func whenTheFileCantBeSwappedItsWrittenInPlace() throws {
        let url = try TestFiles.pdf(pages: ["Written in place"])
        let highlight = try TestFiles.highlight(of: "Written", in: url)
        // Like a file the sandbox lets Sheaf write, in a folder it can't.
        let folder = url.deletingLastPathComponent()
        try TestFiles.setPermissions(0o555, of: folder)
        defer { try? TestFiles.setPermissions(0o755, of: folder) }

        #expect(PDFHighlightWriter.write([highlight], to: url) == .saved)
        #expect(try idsInFile(url) == [highlight.id])
    }

    @Test func aFailedSaveIsTriedAgain() async throws {
        let (model, url) = try makeReader(pages: ["Try this again"])
        model.saveRetryDelays = [.milliseconds(400)]
        let folder = url.deletingLastPathComponent()
        try TestFiles.setPermissions(0o444, of: url)
        try TestFiles.setPermissions(0o555, of: folder)
        defer {
            try? TestFiles.setPermissions(0o755, of: folder)
            try? TestFiles.setPermissions(0o644, of: url)
        }

        try highlight("Try this", in: model)
        await model.saveAndWait()
        #expect(model.saveError != nil)
        #expect(try idsInFile(url).isEmpty)
        #expect(model.entry?.needsFileSave == true, "Kept for next time, too")

        // The drive is writable again: the next try saves.
        try TestFiles.setPermissions(0o755, of: folder)
        try TestFiles.setPermissions(0o644, of: url)
        try await waitUntil { model.saveError == nil }
        #expect(try idsInFile(url) == Set(model.highlights.map(\.id)))
        #expect(model.entry?.needsFileSave == false)
    }

    @Test func aTemporaryLibraryWritesNothingIntoFiles() async throws {
        let temporary = LibraryStore(context: container.mainContext, isTemporaryLibrary: true)
        let (model, url) = try makeReader(store: temporary, pages: ["Nothing changes here"])
        let before = try Data(contentsOf: url)
        #expect(model.fileWriteBlock == .temporaryLibrary)

        try highlight("Nothing changes", in: model)
        await model.saveAndWait()
        model.close()

        #expect(model.highlights.count == 1)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func bigFilesSaveLessOften() {
        #expect(ReaderModel.saveDelay(forFileSize: 2_000_000) == .milliseconds(1500))
        #expect(ReaderModel.saveDelay(forFileSize: 80_000_000) == .seconds(20))
        let middle = ReaderModel.saveDelay(forFileSize: 30_000_000)
        #expect(middle > .milliseconds(1500) && middle < .seconds(20))
    }

    // MARK: Original copies

    @Test func theOriginalIsKeptOnceBeforeTheFirstSave() async throws {
        let originals = try TestFiles.folder()
        let archiving = LibraryStore(context: container.mainContext, originalsFolder: originals)
        let (model, url) = try makeReader(store: archiving, pages: ["Keep the original safe"])
        let before = try Data(contentsOf: url)

        try highlight("Keep the", in: model)
        await model.saveAndWait()
        let copy = originals.appending(path: try #require(model.entry).id.uuidString).appending(path: "Paper.pdf")
        #expect(try Data(contentsOf: copy) == before)

        try highlight("original safe", in: model)
        await model.saveAndWait()
        #expect(try Data(contentsOf: copy) == before, "The first copy stays")
        #expect(try Data(contentsOf: url) != before)
    }

    @Test func originalCopiesSkipHugeFilesAndMakeRoom() throws {
        let folder = try TestFiles.folder()
        var huge = OriginalPDFArchive(folder: folder, pdfID: UUID())
        huge.maxFileSize = 10
        huge.keepCopy(of: Data(count: 11), fileName: "Huge.pdf")
        #expect(!huge.hasCopy)

        func archive() -> OriginalPDFArchive {
            var archive = OriginalPDFArchive(folder: folder, pdfID: UUID())
            archive.maxTotalSize = 250
            return archive
        }
        let first = archive(), second = archive(), third = archive()
        first.keepCopy(of: Data(count: 100), fileName: "First.pdf")
        try FileManager.default.setAttributes(
            [.creationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: folder.appending(path: first.pdfID.uuidString).path(percentEncoded: false)
        )
        second.keepCopy(of: Data(count: 100), fileName: "Second.pdf")
        third.keepCopy(of: Data(count: 100), fileName: "Third.pdf")

        #expect(!first.hasCopy, "The oldest made room")
        #expect(second.hasCopy)
        #expect(third.hasCopy)
    }

    // MARK: Library backups

    @Test func theLibraryIsBackedUpAndTheNewestFiveAreKept() throws {
        let folder = try TestFiles.folder()
        let storeURL = folder.appending(path: "default.store")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: folder.appending(path: "default.store-wal"))
        try Data("shm".utf8).write(to: folder.appending(path: "default.store-shm"))
        let external = folder.appending(path: ".default_SUPPORT/_EXTERNAL_DATA")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: external.appending(path: "cover"))
        let backups = LibraryBackup.folder(for: storeURL)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var made: [URL] = []
        for hour in 0..<7 {
            made.append(try #require(LibraryBackup.backUp(storeURL: storeURL, into: backups, now: start + Double(hour) * 3600)))
        }
        LibraryBackup.prune(backups)

        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false)).sorted()
        #expect(left == made.suffix(5).map(\.lastPathComponent).sorted())
        let newest = try #require(made.last)
        #expect(try Data(contentsOf: newest.appending(path: "default.store")) == Data("store".utf8))
        #expect(try Data(contentsOf: newest.appending(path: "default.store-wal")) == Data("wal".utf8))
        #expect(try Data(contentsOf: newest.appending(path: "default.store-shm")) == Data("shm".utf8))
        #expect(try Data(contentsOf: newest.appending(path: ".default_SUPPORT/_EXTERNAL_DATA/cover")) == Data("cover".utf8))
    }

    @Test func thereIsNothingToBackUpBeforeTheFirstLaunch() throws {
        let folder = try TestFiles.folder()
        #expect(LibraryBackup.backUp(storeURL: folder.appending(path: "default.store")) == nil)
    }
}
