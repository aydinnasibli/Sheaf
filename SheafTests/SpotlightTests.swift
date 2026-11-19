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
    }

    private(set) var changes: [Change] = []

    func index(_ highlights: [SpotlightHighlight]) { changes.append(.indexed(highlights)) }
    func remove(highlightIDs: [UUID]) { changes.append(.removedHighlights(highlightIDs)) }
    func remove(pdfIDs: [UUID]) { changes.append(.removedPDFs(pdfIDs)) }
    func replaceAll(with highlights: [SpotlightHighlight]) { changes.append(.replacedAll(highlights)) }
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
}
