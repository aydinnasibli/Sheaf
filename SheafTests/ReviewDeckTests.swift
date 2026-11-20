import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Flashcards made from highlights.
@MainActor
struct ReviewDeckTests {
    private let container: ModelContainer
    private let store: LibraryStore

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
    }

    private func allHighlights() throws -> [HighlightRecord] {
        try container.mainContext.fetch(FetchDescriptor<HighlightRecord>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    private func makeCards(_ count: Int) -> [ReviewCard] {
        (1...count).map {
            ReviewCard(id: UUID(), entryID: nil, kind: .definition, text: "Card \($0)", note: "", title: "PDF", pageIndex: $0)
        }
    }

    @Test func theDeckPicksTheRightHighlights() throws {
        let biology = store.createCollection(named: "Biology")
        let cells = store.recordOpen(of: URL(filePath: "/Cells.pdf"), document: TestPDF.make(pages: ["1", "2", "3"]))
        let physics = store.recordOpen(of: URL(filePath: "/Physics.pdf"), document: TestPDF.make(pages: ["1"]))
        store.move([cells], to: biology)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let osmosis = store.addHighlight(to: cells, pageIndex: 2, kind: .definition, text: "Osmosis is\nthe movement of water", rects: [], now: start)
        store.setNote("What is osmosis?", for: osmosis)
        store.addHighlight(to: cells, pageIndex: 0, kind: .definition, text: "Diffusion spreads molecules out", rects: [], now: start + 1)
        store.addHighlight(to: cells, pageIndex: 1, kind: .keyIdea, text: "Cells are the unit of life", rects: [], now: start + 2)
        store.addHighlight(to: physics, pageIndex: 0, kind: .definition, text: "Entropy measures disorder", rects: [], now: start + 3)
        store.addHighlight(to: physics, pageIndex: 0, kind: .evidence, text: "Table 2", rects: [], now: start + 4)
        store.addHighlight(to: physics, pageIndex: 0, kind: .definition, text: "   ", rects: [], now: start + 5)
        let records = try allHighlights()

        // By default, Definitions from every PDF (blank highlights are skipped).
        let definitions = ReviewDeck.cards(from: records, kinds: [.definition], source: .all)
        #expect(definitions.map(\.text) == ["Osmosis is the movement of water", "Diffusion spreads molecules out", "Entropy measures disorder"])

        let card = definitions[0]
        #expect(card.id == osmosis.id)
        #expect(card.note == "What is osmosis?")
        #expect(card.title == "Cells")
        #expect(card.pageIndex == 2)
        #expect(card.entryID == cells.id)

        let twoColors = ReviewDeck.cards(from: records, kinds: [.definition, .evidence], source: .all)
        #expect(twoColors.count == 4)
        let inBiology = ReviewDeck.cards(from: records, kinds: [.definition], source: .collection(biology.id))
        #expect(inBiology.map(\.title) == ["Cells", "Cells"])
        let inPhysics = ReviewDeck.cards(from: records, kinds: [.definition], source: .entry(physics.id))
        #expect(inPhysics.map(\.text) == ["Entropy measures disorder"])
        #expect(ReviewDeck.cards(from: records, kinds: [], source: .all).isEmpty)
    }

    @Test func againComesBackLaterAndGotItMovesOn() {
        let cards = makeCards(5)
        let deck = ReviewDeck(cards: cards, kinds: [.definition], source: .all, shuffled: false)
        #expect(deck.current == cards[0])
        #expect(deck.position == 1)

        // The answer has to be shown first.
        deck.gotIt()
        #expect(deck.current == cards[0])

        deck.reveal()
        #expect(deck.isRevealed)
        deck.again()
        #expect(!deck.isRevealed)
        #expect(deck.queue.map(\.text) == ["Card 2", "Card 3", "Card 4", "Card 1", "Card 5"])
        #expect(deck.position == 1)

        deck.reveal()
        deck.gotIt()
        #expect(deck.current == cards[2])
        #expect(deck.position == 2)

        while !deck.isFinished {
            deck.reveal()
            deck.gotIt()
        }
        #expect(deck.doneCount == 5)
        #expect(deck.position == 5)
        #expect(deck.progress == 1)
        #expect(deck.missed == [cards[0]])
    }

    @Test func againNearTheEndGoesLast() {
        let cards = makeCards(2)
        let deck = ReviewDeck(cards: cards, kinds: [.definition], source: .all, shuffled: false)

        deck.reveal()
        deck.again()
        #expect(deck.queue == [cards[1], cards[0]])

        deck.reveal()
        deck.gotIt()
        deck.reveal()
        deck.again()
        // Only one left: it comes straight back, and counts as missed once.
        #expect(deck.queue == [cards[0]])
        #expect(deck.missed == [cards[0]])
    }

    @Test func cardsAreShuffledAndReviewsCanStartOver() {
        let cards = makeCards(30)
        let deck = ReviewDeck(cards: cards, kinds: [.definition], source: .all)
        #expect(Set(deck.cards) == Set(cards))
        #expect(deck.cards.count == 30)

        deck.reveal()
        let first = deck.current
        deck.again()
        let missedOnly = deck.restarted(onlyMissed: true)
        #expect(missedOnly.cards.map(\.id) == [first?.id])
        #expect(Set(deck.restarted(onlyMissed: false).cards) == Set(cards))
    }
}
