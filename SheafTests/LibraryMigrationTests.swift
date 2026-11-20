import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Sheaf

/// The library as it was before page notes, summaries and page labels.
/// Kept as it was then: a library saved by that version must still open.
enum LibraryBeforeNotes: VersionedSchema {
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
        var needsFileSave = false
        var removedHighlightIDs: [UUID] = []
        @Attribute(.externalStorage) var cover: Data?
        var collection: PDFCollection?
        @Relationship(deleteRule: .cascade, inverse: \HighlightRecord.entry)
        var highlights: [HighlightRecord] = []

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
        var entry: LibraryEntry?

        init(pageIndex: Int, text: String) {
            self.pageIndex = pageIndex
            self.kindRaw = 2
            self.text = text
            self.createdAt = .now
            self.rectValues = [72, 700, 100, 14]
        }
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

    @Test func aLibraryFromBeforeNotesOpensWithEverythingInIt() throws {
        let url = try TestFiles.folder().appending(path: "Library.store")
        do {
            let old = try ModelContainer(
                for: Schema(versionedSchema: LibraryBeforeNotes.self), configurations: ModelConfiguration(url: url)
            )
            let entry = LibraryBeforeNotes.LibraryEntry(title: "Attention", path: "/Users/test/Attention.pdf", pageCount: 12)
            entry.furthestPageIndex = 7
            entry.bookmarkedPages = [3]
            let collection = LibraryBeforeNotes.PDFCollection(name: "Thesis")
            let record = LibraryBeforeNotes.HighlightRecord(pageIndex: 4, text: "Self-attention")
            record.note = "Compare with RNNs"
            old.mainContext.insert(entry)
            old.mainContext.insert(collection)
            old.mainContext.insert(record)
            entry.collection = collection
            record.entry = entry
            try old.mainContext.save()
        }

        let new = try ModelContainer(for: Schema(LibraryStore.models), configurations: ModelConfiguration(url: url))
        let entry = try #require(try new.mainContext.fetch(FetchDescriptor<Sheaf.LibraryEntry>()).first)
        #expect(entry.title == "Attention")
        #expect(entry.furthestPageIndex == 7)
        #expect(entry.readPages.isEmpty)
        #expect(entry.progress == 8.0 / 12.0)
        #expect(entry.bookmarkedPages == [3])
        #expect(entry.collection?.name == "Thesis")
        #expect(entry.summary.isEmpty)
        #expect(entry.pageLabels.isEmpty)
        #expect(entry.pageNotes.isEmpty)
        let record = try #require(entry.highlights.first)
        #expect(record.text == "Self-attention")
        #expect(record.note == "Compare with RNNs")
        #expect(record.pageLabel.isEmpty)
        #expect(record.displayPage == "5")
        // Its questions are open until answered.
        #expect(!record.isAnswered)
        #expect(record.answer.isEmpty)
        #expect(entry.openQuestionCount == 1)

        // New things can be added to it.
        let store = LibraryStore(context: new.mainContext)
        store.addPageNote(to: entry, pageIndex: 2, text: "The diagram")
        store.setSummary("About attention", for: entry)
        store.setAnswer("Attention replaces recurrence", isAnswered: true, for: record)
        #expect(entry.pageNotes.map(\.text) == ["The diagram"])
        #expect(entry.openQuestionCount == 0)
    }
}
