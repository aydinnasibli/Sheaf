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

    // MARK: Swaps that fail partway

    @Test func aSwapThatFailsPartwayPutsTheOriginalBack() throws {
        let url = try TestFiles.pdf(pages: ["The original"])
        let original = try Data(contentsOf: url)
        // Moves the original into the temporary folder and fails; then
        // writing in place fails too.
        let steps = SafeFileWriter.Steps(
            swap: { url, replacement in
                try FileManager.default.moveItem(at: url, to: replacement.deletingLastPathComponent().appending(path: "Aside.pdf"))
                throw SwapFailed()
            },
            writeInPlace: { _, _ in throw SwapFailed() }
        )

        #expect(throws: SwapFailed.self) { try SafeFileWriter.replace(url, with: Data("new version".utf8), steps: steps) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func theOriginalComesBackFromWhereTheErrorSaysEvenOnAFullDrive() throws {
        let url = try TestFiles.pdf(pages: ["The original"])
        let original = try Data(contentsOf: url)
        let aside = try TestFiles.folder().appending(path: "Elsewhere.pdf")
        let steps = SafeFileWriter.Steps(
            swap: { url, _ in
                try FileManager.default.moveItem(at: url, to: aside)
                throw NSError(
                    domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
                    userInfo: [SafeFileWriter.originalLocationKey: aside]
                )
            },
            writeInPlace: { _, _ in Issue.record("A file is never written in place on a full drive") }
        )

        #expect(throws: (any Error).self) { try SafeFileWriter.replace(url, with: Data("new version".utf8), steps: steps) }
        #expect(try Data(contentsOf: url) == original)
        #expect(!FileManager.default.fileExists(atPath: aside.path(percentEncoded: false)))
    }

    @Test func withTheOriginalBackTheFileIsWrittenInPlace() throws {
        let url = try TestFiles.pdf(pages: ["The original"])
        let new = Data("new version".utf8)
        let steps = SafeFileWriter.Steps(
            swap: { url, replacement in
                try FileManager.default.moveItem(at: url, to: replacement.deletingLastPathComponent().appending(path: "Aside.pdf"))
                throw SwapFailed()
            },
            writeInPlace: SafeFileWriter.Steps.system.writeInPlace
        )

        try SafeFileWriter.replace(url, with: new, steps: steps)
        #expect(try Data(contentsOf: url) == new)
    }

    @Test func aSwapThatFailsAfterSwappingKeepsTheNewVersion() throws {
        let url = try TestFiles.pdf(pages: ["The original"])
        let new = Data("new version".utf8)
        let steps = SafeFileWriter.Steps(
            swap: { url, replacement in
                let fileManager = FileManager.default
                let parked = replacement.deletingLastPathComponent().appending(path: "Parked.pdf")
                try fileManager.moveItem(at: url, to: parked)
                try fileManager.moveItem(at: replacement, to: url)
                try fileManager.moveItem(at: parked, to: replacement)
                throw SwapFailed()
            },
            writeInPlace: { _, _ in Issue.record("The new version was in place already") }
        )

        try SafeFileWriter.replace(url, with: new, steps: steps)
        #expect(try Data(contentsOf: url) == new)
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
        #expect(model.saveError?.contains("try again shortly") == true)
        #expect(try idsInFile(url).isEmpty)
        #expect(model.entry?.needsFileSave == true, "Kept for next time, too")

        // The drive is writable again: the next try saves.
        try TestFiles.setPermissions(0o755, of: folder)
        try TestFiles.setPermissions(0o644, of: url)
        try await waitUntil { model.saveError == nil }
        #expect(try idsInFile(url) == Set(model.highlights.map(\.id)))
        #expect(model.entry?.needsFileSave == false)
    }

    @Test func afterTheLastRetryTheMessageSaysWhenSheafTriesAgain() async throws {
        let (model, url) = try makeReader(pages: ["Not now but later"])
        model.saveRetryDelays = []
        let folder = url.deletingLastPathComponent()
        try TestFiles.setPermissions(0o444, of: url)
        try TestFiles.setPermissions(0o555, of: folder)
        defer {
            try? TestFiles.setPermissions(0o755, of: folder)
            try? TestFiles.setPermissions(0o644, of: url)
        }

        try highlight("Not now", in: model)
        await model.saveAndWait()
        let message = try #require(model.saveError)
        #expect(!message.contains("shortly"))
        #expect(message.contains("after your next change, when you open this PDF again, and when you quit"))

        // As it says: the next change tries again.
        try TestFiles.setPermissions(0o755, of: folder)
        try TestFiles.setPermissions(0o644, of: url)
        try highlight("but later", in: model)
        await model.saveAndWait()
        #expect(model.saveError == nil)
        #expect(try idsInFile(url) == Set(model.highlights.map(\.id)))
        #expect(model.entry?.needsFileSave == false)
    }

    // MARK: Saves that finish late

    /// Another reader for the PDF at `url`, as when it's opened again.
    private func reopen(_ url: URL, entry: LibraryEntry?) throws -> ReaderModel {
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        return ReaderModel(document: try #require(PDFDocument(url: url)), entry: entry, store: store, fileURL: url, preferences: preferences)
    }

    @Test func aSaveThatFinishesAfterAChangeInTheLibraryLeavesTheFileUnsaved() async throws {
        let (model, url) = try makeReader(pages: ["Late saves lose"])
        try highlight("Late saves", in: model)
        let record = try #require(model.highlights.first)
        let entry = try #require(model.entry)
        // A save starts and the PDF is closed; before the save finishes,
        // a note is written on the Highlights page.
        model.flushPendingSave()
        model.close()
        store.setNote("Written while it saved", for: record)
        await model.saveAndWait()

        #expect(try idsInFile(url) == [record.id])
        #expect(entry.needsFileSave, "The file doesn't have the note yet")

        // Opening the PDF again saves it.
        let reopened = try reopen(url, entry: entry)
        await reopened.saveAndWait()
        #expect(!entry.needsFileSave)
        let notes = try #require(PDFDocument(url: url)?.page(at: 0)).annotations
            .filter { PDFHighlights.id(of: $0) == record.id }.map(\.contents)
        #expect(!notes.isEmpty && notes.allSatisfy { $0 == "Written while it saved" })
    }

    @Test func aSaveFromAClosedReaderDoesntMarkTheReopenedPDFSaved() async throws {
        let (model, url) = try makeReader(pages: ["First thought then a second"])
        try highlight("First thought", in: model)
        let entry = try #require(model.entry)
        model.flushPendingSave()
        model.close()
        // Opened again before that save finished, and highlighted again.
        let reopened = try reopen(url, entry: entry)
        try highlight("a second", in: reopened)
        await model.saveAndWait()

        #expect(entry.needsFileSave, "The second highlight isn't in the file yet")
        await reopened.saveAndWait()
        #expect(!entry.needsFileSave)
        #expect(try idsInFile(url) == Set(entry.highlights.map(\.id)))
        #expect(try idsInFile(url).count == 2)
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

    @Test func theLibraryIsBackedUpWithAllItsFiles() throws {
        let folder = try TestFiles.folder()
        let storeURL = folder.appending(path: "default.store")
        try Data("store".utf8).write(to: storeURL)
        try Data("wal".utf8).write(to: folder.appending(path: "default.store-wal"))
        try Data("shm".utf8).write(to: folder.appending(path: "default.store-shm"))
        let external = folder.appending(path: ".default_SUPPORT/_EXTERNAL_DATA")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: external.appending(path: "cover"))
        let backups = LibraryBackup.folder(for: storeURL)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try #require(LibraryBackup.backUp(storeURL: storeURL, into: backups, now: now))
        let second = try #require(LibraryBackup.backUp(storeURL: storeURL, into: backups, now: now))
        #expect(first.lastPathComponent == LibraryBackup.folderName(for: now))
        #expect(second.lastPathComponent == LibraryBackup.folderName(for: now) + " 2")
        #expect(try Data(contentsOf: second.appending(path: "default.store")) == Data("store".utf8))
        #expect(try Data(contentsOf: second.appending(path: "default.store-wal")) == Data("wal".utf8))
        #expect(try Data(contentsOf: second.appending(path: "default.store-shm")) == Data("shm".utf8))
        #expect(try Data(contentsOf: second.appending(path: ".default_SUPPORT/_EXTERNAL_DATA/cover")) == Data("cover".utf8))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// Backups `hours` apart going back from `newest`, newest first.
    private func backups(every hours: Int, count: Int, from newest: Date) -> [(name: String, date: Date)] {
        (0..<count).map { index in
            let date = newest - Double(index * hours) * 3600
            return (name: LibraryBackup.folderName(for: date), date: date)
        }
    }

    @Test func backupsGoBackAboutAMonthNotJustAFewLaunches() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Opened three times a day for two months.
        let all = backups(every: 8, count: 180, from: now)
        let kept = LibraryBackup.keptBackups(all, calendar: utc)
        let keptDates = all.filter { kept.contains($0.name) }.map(\.date)

        #expect(Set(all.prefix(LibraryBackup.keptCount).map(\.name)).isSubset(of: kept), "The newest few")
        for day in 0..<LibraryBackup.keptDays {
            let start = utc.startOfDay(for: now - Double(day) * 86_400)
            #expect(keptDates.contains { utc.isDate($0, inSameDayAs: start) }, "One from each of the last days")
        }
        let oldest = try #require(keptDates.min())
        #expect(now.timeIntervalSince(oldest) > 28 * 86_400, "One from about a month ago")
        #expect(kept.count <= LibraryBackup.keptCount + LibraryBackup.keptDays + LibraryBackup.keptWeeks)
    }

    @Test func manyLaunchesInOneDayDontPushOutOlderBackups() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A backup a day for 40 days, then twenty launches today (updates
        // relaunch Sheaf), as when a damaged library keeps being backed up.
        let daily = backups(every: 24, count: 40, from: now - 86_400)
        let today = backups(every: 0, count: 20, from: now).enumerated().map { index, backup in
            (name: backup.name + (index == 0 ? "" : " \(index + 1)"), date: backup.date)
        }
        let kept = LibraryBackup.keptBackups(today + daily, calendar: utc)

        #expect(kept.contains(daily[0].name), "Yesterday's")
        #expect(kept.contains(daily[5].name), "From six days ago")
        #expect(daily.contains { kept.contains($0.name) && now.timeIntervalSince($0.date) > 28 * 86_400 }, "From a month ago")
        #expect(today.filter { kept.contains($0.name) }.count == LibraryBackup.keptCount)
        // The newest of today is the one with the highest number.
        #expect(kept.contains(today[19].name))
        #expect(!kept.contains(today[0].name))
    }

    @Test func backupsFromBeforeAFormatChangeAreKeptLonger() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var all = backups(every: 8, count: 180, from: now)
        // Taken 50 days ago, before an update changed the library's format.
        all[150].name += LibraryBackup.formatChangeSuffix
        let kept = LibraryBackup.keptBackups(all, calendar: utc)
        #expect(kept.contains(all[150].name))
        #expect(!kept.contains(all[151].name))
    }

    @Test func pruningDeletesOnlyBackupsTheRulesDontKeep() throws {
        let backupsFolder = try TestFiles.folder()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let all = backups(every: 8, count: 60, from: now)
        for backup in all {
            try FileManager.default.createDirectory(at: backupsFolder.appending(path: backup.name), withIntermediateDirectories: true)
        }
        // Not a backup: left alone.
        try FileManager.default.createDirectory(at: backupsFolder.appending(path: "Keep this"), withIntermediateDirectories: true)

        LibraryBackup.prune(backupsFolder, calendar: utc)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: backupsFolder.path(percentEncoded: false)))
        #expect(left == LibraryBackup.keptBackups(all, calendar: utc).union(["Keep this"]))
        #expect(left.count < all.count)
    }

    @Test func thereIsNothingToBackUpBeforeTheFirstLaunch() throws {
        let folder = try TestFiles.folder()
        #expect(LibraryBackup.backUp(storeURL: folder.appending(path: "default.store")) == nil)
    }
}

/// A swap that went wrong, in the fakes above.
private struct SwapFailed: Error {}
