import CoreGraphics
import CoreSpotlight
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import Sheaf

/// Records what the library tells the index, in place of Spotlight.
@MainActor
final class FakeHighlightIndex: HighlightIndexing {
    enum Change: Equatable {
        case indexed([SpotlightHighlight])
        case removedHighlights([UUID])
        case removedPDFs([UUID])
        case replacedAll([SpotlightHighlight])
        case indexedNotes([SpotlightNote])
        case removedNotes([String])
    }

    private(set) var changes: [Change] = []

    func index(_ highlights: [SpotlightHighlight]) { changes.append(.indexed(highlights)) }
    func remove(highlightIDs: [UUID]) { changes.append(.removedHighlights(highlightIDs)) }
    func remove(pdfIDs: [UUID]) { changes.append(.removedPDFs(pdfIDs)) }
    func replaceAll(with highlights: [SpotlightHighlight]) { changes.append(.replacedAll(highlights)) }
    func index(notes: [SpotlightNote]) { changes.append(.indexedNotes(notes)) }
    func remove(noteIdentifiers: [String]) { changes.append(.removedNotes(noteIdentifiers)) }
}

@MainActor
struct SpotlightTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let index = FakeHighlightIndex()

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        store.searchIndex = index
    }

    private func makeEntry(title: String = "Attention Is All You Need") -> LibraryEntry {
        let entry = LibraryEntry(title: title, path: "/Users/test/\(title).pdf", pageCount: 12)
        container.mainContext.insert(entry)
        return entry
    }

    @discardableResult
    private func addHighlight(to entry: LibraryEntry, text: String = "Self-attention relates positions") -> HighlightRecord {
        store.addHighlight(to: entry, pageIndex: 3, kind: .question, text: text, rects: [CGRect(x: 72, y: 600, width: 200, height: 14)])
    }

    // MARK: The Spotlight item

    @Test func aHighlightBecomesASpotlightItem() throws {
        let entry = makeEntry()
        let record = addHighlight(to: entry)
        store.setNote("Check against RNNs", for: record)

        let highlight = try #require(SpotlightHighlight(record))
        let item = highlight.searchableItem()

        #expect(item.uniqueIdentifier == record.id.uuidString)
        #expect(item.domainIdentifier == entry.id.uuidString)
        #expect(item.attributeSet.title == "Self-attention relates positions")
        #expect(item.attributeSet.contentDescription
            == "Check against RNNs\nQuestion on page 4 of \u{201C}Attention Is All You Need\u{201D}")
        #expect(item.attributeSet.contentType == UTType.text.identifier)
        #expect(item.attributeSet.keywords == ["Question"])
        #expect(item.expirationDate == .distantFuture)
    }

    @Test func withoutANoteTheItemSaysWhereTheHighlightIs() throws {
        let record = addHighlight(to: makeEntry(title: "Contract"))

        let item = try #require(SpotlightHighlight(record)).searchableItem()

        #expect(item.attributeSet.contentDescription == "Question on page 4 of \u{201C}Contract\u{201D}")
    }

    @Test func aHighlightWithoutAPDFIsNotIndexed() {
        let record = HighlightRecord(pageIndex: 0, kind: .keyIdea, text: "Loose", rects: [])
        container.mainContext.insert(record)
        #expect(SpotlightHighlight(record) == nil)
    }

    // MARK: Keeping the index in sync

    @Test func addingAndChangingAHighlightIndexesItAgain() throws {
        let entry = makeEntry()
        let record = addHighlight(to: entry)
        store.setNote("  Follow up  ", for: record)
        store.setKind(.evidence, for: record)

        let indexed = index.changes.compactMap { change -> SpotlightHighlight? in
            if case .indexed(let highlights) = change { return highlights.first }
            return nil
        }
        #expect(index.changes.count == 3)
        #expect(indexed.allSatisfy { $0.id == record.id && $0.pdfID == entry.id && $0.pageIndex == 3 })
        #expect(indexed.map(\.note) == ["", "Follow up", "Follow up"])
        #expect(indexed.map(\.kindName) == ["Question", "Question", "Evidence"])
    }

    @Test func deletingAHighlightRemovesItAndUndoBringsItBack() throws {
        let entry = makeEntry()
        let record = addHighlight(to: entry)
        let snapshot = HighlightSnapshot(record)

        store.delete(record)
        #expect(index.changes.last == .removedHighlights([snapshot.id]))

        store.restoreHighlight(snapshot, to: entry)
        guard case .indexed(let highlights) = index.changes.last else {
            Issue.record("Restoring didn't index the highlight")
            return
        }
        #expect(highlights.map(\.id) == [snapshot.id])
    }

    @Test func removingAPDFRemovesAllItsHighlights() throws {
        let first = makeEntry(title: "One")
        let second = makeEntry(title: "Two")
        addHighlight(to: first)

        store.remove([first, second])

        #expect(index.changes.last == .removedPDFs([first.id, second.id]))
    }

    @Test func rebuildingTheIndexUsesEveryHighlightInAPDF() throws {
        let entry = makeEntry()
        let one = addHighlight(to: entry, text: "One")
        let two = addHighlight(to: entry, text: "Two")
        container.mainContext.insert(HighlightRecord(pageIndex: 0, kind: .keyIdea, text: "Loose", rects: []))

        let highlights = store.spotlightHighlights()

        #expect(Set(highlights.map(\.id)) == [one.id, two.id])
    }

    // MARK: Page notes and summaries

    private func makeWatcher() -> SpotlightNotesWatcher {
        let watcher = SpotlightNotesWatcher(context: container.mainContext, index: index)
        watcher.startWatching()
        return watcher
    }

    private var indexedNotes: [[SpotlightNote]] {
        index.changes.compactMap { change in
            if case .indexedNotes(let notes) = change { return notes }
            return nil
        }
    }

    @Test func aPageNoteBecomesASpotlightItemThatOpensItsPage() throws {
        let entry = makeEntry()
        let note = PageNote(pageIndex: 4, pageLabel: "xii", text: "Compare with figure 2\nand the appendix")
        container.mainContext.insert(note)
        note.entry = entry

        let item = try #require(SpotlightNote(note)).searchableItem()

        #expect(item.uniqueIdentifier == "note-\(note.id.uuidString)")
        #expect(item.domainIdentifier == entry.id.uuidString)
        #expect(item.attributeSet.title == "Compare with figure 2")
        #expect(item.attributeSet.contentDescription
            == "Compare with figure 2\nand the appendix\nNote on page xii of \u{201C}Attention Is All You Need\u{201D}")
        #expect(SpotlightNote.Target(identifier: item.uniqueIdentifier) == .pageNote(note.id))
        #expect(SpotlightNote.Target(identifier: entry.id.uuidString) == .highlight(entry.id))
        #expect(SpotlightNote.Target(identifier: "summary-\(entry.id.uuidString)") == .summary(pdfID: entry.id))
        #expect(SpotlightNote.Target(identifier: "something else") == nil)
    }

    @Test func writingChangingAndDeletingPageNotesReachSpotlight() async throws {
        let entry = makeEntry()
        store.save()
        let watcher = makeWatcher()

        let note = store.addPageNote(to: entry, pageIndex: 2, text: "Key definition here")
        // SwiftData tells of each save a moment later.
        try await waitUntil { indexedNotes.last?.map(\.text) == ["Key definition here"] }
        #expect(indexedNotes.last?.first?.identifier == "note-\(note.id.uuidString)")

        store.setText("Key definition, revised", for: note)
        try await waitUntil { indexedNotes.last?.map(\.text) == ["Key definition, revised"] }

        let id = note.id
        store.delete(note)
        try await waitUntil { index.changes.last == .removedNotes(["note-\(id.uuidString)"]) }
        _ = watcher
    }

    @Test func summariesReachSpotlightAndRenamingUpdatesNotes() async throws {
        let entry = makeEntry(title: "Cells")
        store.save()
        let watcher = makeWatcher()
        store.addPageNote(to: entry, pageIndex: 0, text: "Membranes")
        try await waitUntil { indexedNotes.count == 1 }
        #expect(watcher.allNotes().count == 1)

        // Reading on (saving the page) doesn't send anything again.
        entry.recordPage(3)
        store.save()
        store.setSummary("Cells are made of smaller parts.", for: entry)
        try await waitUntil { indexedNotes.count == 2 }
        let summary = try #require(indexedNotes.last?.first)
        #expect(indexedNotes.last?.count == 1)
        #expect(summary.identifier == "summary-\(entry.id.uuidString)")
        #expect(summary.searchableItem().attributeSet.title == "My summary of \u{201C}Cells\u{201D}")

        store.rename(entry, to: "Cell Biology")
        try await waitUntil { indexedNotes.count == 3 }
        #expect(Set(try #require(indexedNotes.last).map(\.pdfTitle)) == ["Cell Biology"])
        #expect(indexedNotes.last?.count == 2)

        store.setSummary("", for: entry)
        try await waitUntil { index.changes.last == .removedNotes(["summary-\(entry.id.uuidString)"]) }
    }

    @Test func rebuildingTheIndexIncludesNotesAndSummaries() throws {
        let entry = makeEntry()
        entry.summary = "In short"
        let note = PageNote(pageIndex: 1, text: "A note")
        container.mainContext.insert(note)
        note.entry = entry
        let empty = PageNote(pageIndex: 2, text: "  ")
        container.mainContext.insert(empty)
        empty.entry = entry
        store.save()

        let notes = SpotlightNotesWatcher(context: container.mainContext, index: index).allNotes()

        #expect(Set(notes.map(\.identifier)) == ["note-\(note.id.uuidString)", "summary-\(entry.id.uuidString)"])
    }
}
