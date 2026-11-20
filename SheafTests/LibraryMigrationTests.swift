import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Sheaf

/// The library exactly as the last build before page notes stored it
/// (commit 9e2575b, "Back and Forward after jumps, page bookmarks, and
/// printing"): its models copied as they were, without the methods. A
/// library saved by that build must open with everything in it.
enum LibraryAt9e2575b: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [LibraryEntry.self, PDFCollection.self, HighlightRecord.self] }

    @Model
    final class LibraryEntry {
        var id = UUID()
        var title: String
        var lastKnownPath: String
        var bookmark: Data?
        var pageCount: Int
        var lastPageIndex = 0
        var furthestPageIndex = 0
        var addedAt: Date
        var lastOpenedAt: Date
        var isStarred = false
        var bookmarkedPages: [Int] = []
        @Attribute(.externalStorage) var cover: Data?
        var collection: PDFCollection?
        @Relationship(deleteRule: .cascade, inverse: \HighlightRecord.entry)
        var highlights: [HighlightRecord] = []

        init(title: String, path: String, pageCount: Int, now: Date = .now) {
            self.title = title
            self.lastKnownPath = path
            self.pageCount = pageCount
            self.addedAt = now
            self.lastOpenedAt = now
        }
    }

    @Model
    final class PDFCollection {
        var id = UUID()
        var name: String
        var colorIndex: Int
        var createdAt: Date
        @Relationship(deleteRule: .nullify, inverse: \LibraryEntry.collection)
        var items: [LibraryEntry] = []

        init(name: String, colorIndex: Int, now: Date = .now) {
            self.name = name
            self.colorIndex = colorIndex
            self.createdAt = now
        }
    }

    @Model
    final class HighlightRecord {
        var id = UUID()
        var pageIndex: Int
        var kindRaw: Int
        var text: String
        var note = ""
        var createdAt: Date
        var rectValues: [Double]
        var entry: LibraryEntry?

        init(pageIndex: Int, kindRaw: Int, text: String, rectValues: [Double], now: Date = .now) {
            self.pageIndex = pageIndex
            self.kindRaw = kindRaw
            self.text = text
            self.createdAt = now
            self.rectValues = rectValues
        }
    }

    /// Saves a library made by that build at `url`, with what's described
    /// in `Saved`, and closes it.
    @MainActor static func saveLibrary(at url: URL) throws {
        let container = try ModelContainer(for: Schema(versionedSchema: Self.self), configurations: ModelConfiguration(url: url))
        let context = container.mainContext

        let thesis = PDFCollection(name: "Thesis", colorIndex: 3, now: Saved.collectionCreated)
        thesis.id = Saved.collectionID
        let attention = LibraryEntry(title: "Attention", path: "/Users/test/Attention.pdf", pageCount: 12, now: Saved.added)
        attention.id = Saved.entryID
        attention.bookmark = Saved.bookmark
        attention.lastPageIndex = 5
        attention.furthestPageIndex = 7
        attention.lastOpenedAt = Saved.opened
        attention.isStarred = true
        attention.bookmarkedPages = [3, 9]
        attention.cover = Saved.cover
        let notes = LibraryEntry(title: "Notes", path: "/Users/test/Notes.pdf", pageCount: 2, now: Saved.added)
        let first = HighlightRecord(pageIndex: 4, kindRaw: 2, text: "Self-attention", rectValues: [72, 700, 100, 14], now: Saved.highlighted)
        first.id = Saved.highlightID
        first.note = "Compare with RNNs"
        let second = HighlightRecord(pageIndex: 6, kindRaw: 4, text: "Two lines", rectValues: [72, 500, 300, 14, 72, 486, 120, 14])

        for model in [thesis, attention, notes, first, second] as [any PersistentModel] {
            context.insert(model)
        }
        attention.collection = thesis
        first.entry = attention
        second.entry = attention
        try context.save()
    }

    /// What `saveLibrary` saved.
    enum Saved {
        static let entryID = UUID()
        static let collectionID = UUID()
        static let highlightID = UUID()
        static let added = Date(timeIntervalSince1970: 1_790_000_000)
        static let opened = Date(timeIntervalSince1970: 1_790_100_000)
        static let collectionCreated = Date(timeIntervalSince1970: 1_789_000_000)
        static let highlighted = Date(timeIntervalSince1970: 1_790_050_000)
        static let bookmark = Data("bookmark bytes".utf8)
        /// Large enough that SwiftData keeps it in a file of its own.
        static let cover = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    }
}

/// The library as it was before pages read were kept one by one
/// (`LibraryEntry.readPages`): progress was the furthest page reached.
/// Kept as it was then: a library saved by that version must still open.
enum LibraryBeforeReadPages: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [LibraryEntry.self, PDFCollection.self, HighlightRecord.self, PageNote.self]
    }

    @Model
    final class LibraryEntry {
        var id = UUID()
        var title: String
        var lastKnownPath: String
        var bookmark: Data?
        var pageCount: Int
        var lastPageIndex = 0
        var furthestPageIndex = 0
        var addedAt: Date
        var lastOpenedAt: Date
        var isStarred = false
        var bookmarkedPages: [Int] = []
        var needsFileSave = false
        var removedHighlightIDs: [UUID] = []
        var summary = ""
        var pageLabels: [String] = []
        @Attribute(.externalStorage) var cover: Data?
        var collection: PDFCollection?
        @Relationship(deleteRule: .cascade, inverse: \HighlightRecord.entry)
        var highlights: [HighlightRecord] = []
        @Relationship(deleteRule: .cascade, inverse: \PageNote.entry)
        var pageNotes: [PageNote] = []

        init(title: String, path: String, pageCount: Int) {
            self.title = title
            self.lastKnownPath = path
            self.pageCount = pageCount
            self.addedAt = .now
            self.lastOpenedAt = .now
        }
    }

    @Model
    final class PDFCollection {
        var id = UUID()
        var name: String
        var colorIndex: Int
        var createdAt: Date
        @Relationship(deleteRule: .nullify, inverse: \LibraryEntry.collection)
        var items: [LibraryEntry] = []

        init(name: String) {
            self.name = name
            self.colorIndex = 0
            self.createdAt = .now
        }
    }

    @Model
    final class HighlightRecord {
        var id = UUID()
        var pageIndex: Int
        var kindRaw: Int
        var text: String
        var note = ""
        var createdAt: Date
        var rectValues: [Double]
        var pageLabel = ""
        var isAnswered = false
        var answer = ""
        var entry: LibraryEntry?

        init(pageIndex: Int, text: String) {
            self.pageIndex = pageIndex
            self.kindRaw = 2
            self.text = text
            self.createdAt = .now
            self.rectValues = [72, 700, 100, 14]
        }
    }

    @Model
    final class PageNote {
        var id = UUID()
        var pageIndex: Int
        var pageLabel = ""
        var text: String
        var createdAt: Date
        var modifiedAt: Date
        var entry: LibraryEntry?

        init(pageIndex: Int, text: String) {
            self.pageIndex = pageIndex
            self.text = text
            self.createdAt = .now
            self.modifiedAt = .now
        }
    }
}

@MainActor
struct LibraryMigrationTests {
    @Test func aLibraryFromBeforeReadPagesKeepsItsProgressAndNotes() throws {
        let url = try TestFiles.folder().appending(path: "Library.store")
        do {
            let old = try ModelContainer(
                for: Schema(versionedSchema: LibraryBeforeReadPages.self), configurations: ModelConfiguration(url: url)
            )
            let entry = LibraryBeforeReadPages.LibraryEntry(title: "Attention", path: "/Users/test/Attention.pdf", pageCount: 10)
            entry.furthestPageIndex = 4
            entry.lastPageIndex = 4
            entry.summary = "About attention"
            entry.pageLabels = (1...10).map { "p\($0)" }
            let note = LibraryBeforeReadPages.PageNote(pageIndex: 2, text: "The diagram")
            let record = LibraryBeforeReadPages.HighlightRecord(pageIndex: 3, text: "Why softmax?")
            record.pageLabel = "p4"
            record.isAnswered = true
            record.answer = "It normalizes"
            old.mainContext.insert(entry)
            old.mainContext.insert(note)
            old.mainContext.insert(record)
            note.entry = entry
            record.entry = entry
            try old.mainContext.save()
        }

        let new = try ModelContainer(for: Schema(LibraryStore.models), configurations: ModelConfiguration(url: url))
        let entry = try #require(try new.mainContext.fetch(FetchDescriptor<Sheaf.LibraryEntry>()).first)
        #expect(entry.summary == "About attention")
        #expect(entry.pageNotes.map(\.text) == ["The diagram"])
        let record = try #require(entry.highlights.first)
        #expect(record.answer == "It normalizes")
        #expect(record.pageLabel == "p4")
        // Pages up to the furthest one still count as read.
        #expect(entry.readPages.isEmpty)
        #expect(entry.furthestPageIndex == 4)
        #expect(entry.progress == 0.5)
        #expect(entry.hasRead(4) && !entry.hasRead(5))
        #expect(entry.readingStatus == .inProgress)

        // Pages read from now on are kept one by one.
        entry.recordRead(8)
        #expect(entry.readPages == [8])
        #expect(entry.progress == 0.6)
        try new.mainContext.save()
    }

    @Test func aLibraryFromTheLastBuildBeforeNotesOpensWithEverythingInIt() throws {
        let url = try TestFiles.folder().appending(path: "Library.store")
        try LibraryAt9e2575b.saveLibrary(at: url)
        typealias Saved = LibraryAt9e2575b.Saved

        let new = try ModelContainer(for: Schema(LibraryStore.models), configurations: ModelConfiguration(url: url))
        let entries = try new.mainContext.fetch(FetchDescriptor<Sheaf.LibraryEntry>())
        #expect(entries.count == 2)
        let entry = try #require(entries.first { $0.id == Saved.entryID })
        #expect(entry.title == "Attention")
        #expect(entry.lastKnownPath == "/Users/test/Attention.pdf")
        #expect(entry.bookmark == Saved.bookmark)
        #expect(entry.pageCount == 12)
        #expect(entry.lastPageIndex == 5)
        #expect(entry.furthestPageIndex == 7)
        #expect(entry.addedAt == Saved.added)
        #expect(entry.lastOpenedAt == Saved.opened)
        #expect(entry.isStarred)
        #expect(entry.bookmarkedPages == [3, 9])
        // Pages up to the furthest one count as read.
        #expect(entry.readPages.isEmpty)
        #expect(entry.progress == 8.0 / 12.0)
        #expect(entry.cover == Saved.cover)

        let collection = try #require(entry.collection)
        #expect(collection.id == Saved.collectionID)
        #expect(collection.name == "Thesis")
        #expect(collection.colorIndex == 3)
        #expect(collection.createdAt == Saved.collectionCreated)
        #expect(collection.items.map(\.id) == [Saved.entryID])

        let highlights = entry.highlights.sorted { $0.pageIndex < $1.pageIndex }
        #expect(highlights.count == 2)
        let record = try #require(highlights.first)
        #expect(record.id == Saved.highlightID)
        #expect(record.pageIndex == 4)
        #expect(record.kindRaw == 2)
        #expect(record.text == "Self-attention")
        #expect(record.note == "Compare with RNNs")
        #expect(record.createdAt == Saved.highlighted)
        #expect(record.rects == [CGRect(x: 72, y: 700, width: 100, height: 14)])
        #expect(highlights.last?.rects.count == 2)
        #expect(highlights.last?.note.isEmpty == true)

        // What that build didn't have starts out empty.
        #expect(!entry.needsFileSave)
        #expect(entry.removedHighlightIDs.isEmpty)
        #expect(entry.summary.isEmpty)
        #expect(entry.pageLabels.isEmpty)
        #expect(entry.pageNotes.isEmpty)
        #expect(record.pageLabel.isEmpty)
        #expect(record.displayPage == "5")
        // Its questions are open until answered.
        #expect(!record.isAnswered)
        #expect(record.answer.isEmpty)
        #expect(entry.openQuestionCount == 1)
        let other = try #require(entries.first { $0.id != Saved.entryID })
        #expect(other.title == "Notes")
        #expect(other.collection == nil)
        #expect(other.highlights.isEmpty)

        // New things can be added to it.
        let store = LibraryStore(context: new.mainContext)
        store.addPageNote(to: entry, pageIndex: 2, text: "The diagram")
        store.setSummary("About attention", for: entry)
        store.setAnswer("Attention replaces recurrence", isAnswered: true, for: record)
        #expect(entry.pageNotes.map(\.text) == ["The diagram"])
        #expect(entry.openQuestionCount == 0)
    }

    @Test func aBackupTakenBeforeTheLibraryFormatChangesIsMarked() throws {
        let folder = try TestFiles.folder()
        let url = folder.appending(path: "Library.store")
        let backups = folder.appending(path: "Library Backups")
        try LibraryAt9e2575b.saveLibrary(at: url)
        #expect(LibraryBackup.formatDiffers(storeURL: url, from: LibraryStore.models))

        let before = try #require(LibraryBackup.backUp(storeURL: url, into: backups))
        #expect(before.lastPathComponent.hasSuffix(LibraryBackup.formatChangeSuffix))
        // The copy is the library as that build left it.
        #expect(LibraryBackup.formatDiffers(storeURL: before.appending(path: "Library.store"), from: LibraryStore.models))

        // Opened by this build, the library is converted; later backups aren't marked.
        do {
            let container = try ModelContainer(for: Schema(LibraryStore.models), configurations: ModelConfiguration(url: url))
            #expect(try container.mainContext.fetchCount(FetchDescriptor<Sheaf.LibraryEntry>()) == 2)
        }
        #expect(!LibraryBackup.formatDiffers(storeURL: url, from: LibraryStore.models))
        let after = try #require(LibraryBackup.backUp(storeURL: url, into: backups, now: .now + 60))
        #expect(!after.lastPathComponent.contains(LibraryBackup.formatChangeSuffix))
    }

    @Test func aLibraryInTodaysFormatIsNotTakenForAnOldOne() throws {
        let url = try TestFiles.folder().appending(path: "Library.store")
        do {
            let container = try ModelContainer(for: Schema(LibraryStore.models), configurations: ModelConfiguration(url: url))
            container.mainContext.insert(Sheaf.LibraryEntry(title: "New", path: "/Users/test/New.pdf", pageCount: 1))
            try container.mainContext.save()
        }
        #expect(!LibraryBackup.formatDiffers(storeURL: url, from: LibraryStore.models))
        // Nor is something that isn't a library.
        let junk = try TestFiles.folder().appending(path: "Junk.store")
        try Data("junk".utf8).write(to: junk)
        #expect(!LibraryBackup.formatDiffers(storeURL: junk, from: LibraryStore.models))
    }
}
