import Foundation
import Observation

/// One flashcard, made from a highlight. It's a copy, so a review keeps
/// working if the highlight is changed or deleted meanwhile.
struct ReviewCard: Identifiable, Hashable {
    /// The highlight's ID.
    let id: UUID
    let entryID: UUID?
    let kind: HighlightKind
    /// The highlighted text: the answer.
    let text: String
    /// The highlight's note, shown as the question when there is one.
    let note: String
    let title: String
    /// 0-based.
    let pageIndex: Int
}

extension ReviewCard {
    init(_ record: HighlightRecord) {
        self.init(
            id: record.id,
            entryID: record.entry?.id,
            kind: record.kind,
            // PDF text keeps the line breaks of the page; a card reads better without them.
            text: record.text.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            note: record.note,
            title: record.entry?.title ?? "PDF",
            pageIndex: record.pageIndex
        )
    }
}

/// Which PDFs a review takes its cards from.
enum ReviewSource: Hashable {
    case all
    case collection(UUID)
    case entry(UUID)

    func contains(_ entry: LibraryEntry) -> Bool {
        switch self {
        case .all: true
        case .collection(let id): entry.collection?.id == id
        case .entry(let id): entry.id == id
        }
    }
}

/// A review: highlights as flashcards, one at a time, shuffled. The front
/// of a card is a cue (the note, or where the highlight is); the highlighted
/// text is the answer. "Again" puts the card back a few cards later, "Got it"
/// moves on, and the review ends when every card has had a "Got it".
/// Results last only for the session.
@Observable
final class ReviewDeck {
    /// After "Again", a card comes back once this many others have been
    /// seen, or at the end if fewer are left.
    static let againSpacing = 3

    let kinds: Set<HighlightKind>
    let source: ReviewSource
    /// Every card in this review.
    let cards: [ReviewCard]
    /// Cards still to answer "Got it"; the first is on screen.
    private(set) var queue: [ReviewCard]
    /// Whether the card on screen shows its answer.
    private(set) var isRevealed = false
    /// Cards answered "Again" at least once, in the order that happened.
    private(set) var missed: [ReviewCard] = []
    /// How many cards are done.
    private(set) var doneCount = 0

    init(cards: [ReviewCard], kinds: Set<HighlightKind>, source: ReviewSource, shuffled: Bool = true) {
        self.cards = shuffled ? cards.shuffled() : cards
        self.queue = self.cards
        self.kinds = kinds
        self.source = source
    }

    /// Cards for the highlights of these colors in these PDFs, in the order given.
    static func cards(from records: [HighlightRecord], kinds: Set<HighlightKind>, source: ReviewSource) -> [ReviewCard] {
        records.compactMap { record in
            guard kinds.contains(record.kind),
                  let entry = record.entry, source.contains(entry),
                  !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return ReviewCard(record)
        }
    }

    var current: ReviewCard? { queue.first }
    var isFinished: Bool { queue.isEmpty }
    /// The card on screen's place in the review, like the 4 in "4 of 20".
    var position: Int { min(doneCount + 1, cards.count) }
    /// From 0 to 1.
    var progress: Double { cards.isEmpty ? 1 : Double(doneCount) / Double(cards.count) }

    func reveal() {
        guard current != nil else { return }
        isRevealed = true
    }

    /// Didn't remember it: the card comes back later in the review.
    func again() {
        guard isRevealed, !queue.isEmpty else { return }
        let card = queue.removeFirst()
        if !missed.contains(card) { missed.append(card) }
        queue.insert(card, at: min(Self.againSpacing, queue.count))
        isRevealed = false
    }

    /// Remembered it: on to the next card.
    func gotIt() {
        guard isRevealed, !queue.isEmpty else { return }
        queue.removeFirst()
        doneCount += 1
        isRevealed = false
    }

    /// A new review of the same cards, or of only the ones that needed "Again".
    func restarted(onlyMissed: Bool) -> ReviewDeck {
        ReviewDeck(cards: onlyMissed ? missed : cards, kinds: kinds, source: source)
    }
}
