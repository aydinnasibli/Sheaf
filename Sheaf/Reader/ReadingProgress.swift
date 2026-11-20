import Foundation

/// Decides when pages count as read, for the library's "Read" percentage
/// and "Finished". Following a link to the references or jumping to the
/// last page isn't reading it, so pages count only when she gets there by
/// reading on (turning pages or scrolling on from a page she'd read, or
/// from the start of the PDF), or after a page has stayed on screen for a
/// while (`ReaderModel.readingDwell`): then that page counts, and not the
/// ones before it.
struct ReadingProgress {
    /// The pages on screen the last time they changed: one, or a pair in
    /// the two-page layouts.
    private(set) var lastPages: [Int] = []
    /// Set just before a jump (a link, the contents, Go to Page, Back…),
    /// so the page change it causes isn't taken for reading.
    private var jumpDeadline: ContinuousClock.Instant?

    /// Reading moves a page or two at a time (a spread in the two-page
    /// layouts); anything further is a jump, like dragging the scroll bar
    /// to the end or pressing End.
    static let readingStep = 2

    /// The furthest page on screen the last time the pages changed.
    var lastPage: Int? { lastPages.last }

    /// Where reading starts: the pages the PDF opened at.
    mutating func start(at pages: [Int]) {
        lastPages = pages
        jumpDeadline = nil
    }

    /// A jump is about to happen. The page change it causes arrives within
    /// a moment, or not at all if the jump stays on the same page.
    mutating func jumpStarting(now: ContinuousClock.Instant = .now) {
        jumpDeadline = now + .seconds(1)
    }

    /// The pages on screen changed to `pages`. Returns the pages that this
    /// counts as read right away: when she read on, the ones she read her
    /// way through, from those on screen before to these; otherwise none.
    /// (Pages that don't count now can still count once they've been on
    /// screen for a while.)
    mutating func arrive(at pages: [Int], hasRead: (Int) -> Bool, now: ContinuousClock.Instant = .now) -> [Int] {
        defer { lastPages = pages }
        let isJump = jumpDeadline.map { now < $0 } ?? false
        jumpDeadline = nil
        guard !isJump, let from = lastPages.last, let fromFirst = lastPages.first, let to = pages.last else { return [] }
        // Forward by a page or a spread.
        guard to > from, to - from <= Self.readingStep else { return [] }
        // Reading on from a page she hadn't read (one she jumped to, say)
        // doesn't count either: she may be looking around the references.
        // The start of the PDF is where reading begins, so it counts.
        guard fromFirst == 0 || hasRead(from) else { return [] }
        return Array(fromFirst...to)
    }
}
