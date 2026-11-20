import Foundation

/// Decides when a page counts as read, for the library's "Read" percentage
/// and "Finished". Following a link to the references or jumping to the
/// last page isn't reading it, so a page counts only when she gets there by
/// reading on (turning pages or scrolling from a page she'd read), or after
/// it has stayed on screen for a while (`ReaderModel.readingDwell`).
struct ReadingProgress {
    /// The furthest page on screen the last time the page changed.
    private(set) var lastPage: Int?
    /// Set just before a jump (a link, the contents, Go to Page, Back…),
    /// so the page change it causes isn't taken for reading.
    private var jumpDeadline: ContinuousClock.Instant?

    /// Reading moves a page or two at a time (a spread in the two-page
    /// layouts); anything further is a jump, like dragging the scroll bar
    /// to the end or pressing End.
    static let readingStep = 2

    /// Where reading starts: the page the PDF opened at.
    mutating func start(at page: Int) {
        lastPage = page
        jumpDeadline = nil
    }

    /// A jump is about to happen. The page change it causes arrives within
    /// a moment, or not at all if the jump stays on the same page.
    mutating func jumpStarting(now: ContinuousClock.Instant = .now) {
        jumpDeadline = now + .seconds(1)
    }

    /// The furthest page on screen changed to `page`. Returns whether that
    /// counts as reading it right away. (A page that doesn't can still count
    /// once it has been on screen for a while.)
    mutating func arrive(at page: Int, furthestRead: Int, now: ContinuousClock.Instant = .now) -> Bool {
        defer { lastPage = page }
        let isJump = jumpDeadline.map { now < $0 } ?? false
        jumpDeadline = nil
        guard !isJump, let lastPage else { return false }
        // Reading on from a page she hadn't read (one she jumped to, say)
        // doesn't count either: she may be looking around the references.
        return page - lastPage <= Self.readingStep && lastPage <= furthestRead
    }
}
