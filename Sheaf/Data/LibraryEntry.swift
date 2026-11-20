import CoreGraphics
import Foundation
import SwiftData

/// A PDF in the library. The file stays wherever the user keeps it; Sheaf
/// stores a security-scoped bookmark so it can find the file again, even
/// after it's moved or renamed.
@Model
final class LibraryEntry {
    var id = UUID()
    var title: String
    /// Where the file was last seen. Used to match a PDF opened from Finder
    /// to its library entry, and shown when the file can't be found.
    var lastKnownPath: String
    var bookmark: Data?
    var pageCount: Int
    /// The page the reader was on when they last closed this PDF (0-based).
    var lastPageIndex = 0
    /// The furthest page reached (0-based). Drives the "Read" percentage.
    var furthestPageIndex = 0
    var addedAt: Date
    var lastOpenedAt: Date
    var isStarred = false
    /// Bookmarked pages (0-based), in order. Kept in Sheaf only: PDF has no
    /// standard place for page bookmarks.
    var bookmarkedPages: [Int] = []
    /// Highlight changes not yet written into the PDF file (Sheaf quit
    /// before a save finished, or it failed). Opening the PDF saves them.
    var needsFileSave = false
    /// Highlights deleted in Sheaf that may still be in the PDF file. The
    /// next save takes them out; until then, opening the file doesn't bring
    /// them back into the library.
    var removedHighlightIDs: [UUID] = []
    /// Her summary of the PDF, in her own words ("My summary"). Kept in
    /// Sheaf only, not in the file.
    var summary = ""
    /// The PDF's printed page labels ("i", "ii", "1", …), one per page, when
    /// they differ from plain page numbers. Remembered because saving
    /// highlights into a PDF loses its labels (PDFKit doesn't write them).
    var pageLabels: [String] = []
    /// A small image of the first page, as PNG.
    @Attribute(.externalStorage) var cover: Data?
    var collection: PDFCollection?
    @Relationship(deleteRule: .cascade, inverse: \HighlightRecord.entry)
    var highlights: [HighlightRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \PageNote.entry)
    var pageNotes: [PageNote] = []

    init(title: String, path: String, pageCount: Int, now: Date = .now) {
        self.title = title
        self.lastKnownPath = path
        self.pageCount = pageCount
        self.addedAt = now
        self.lastOpenedAt = now
    }

    /// How much has been read, from 0 to 1.
    var progress: Double {
        guard pageCount > 0 else { return 0 }
        return min(1, Double(furthestPageIndex + 1) / Double(pageCount))
    }

    var readingStatus: ReadingStatus {
        if furthestPageIndex == 0 && lastPageIndex == 0 { return .unread }
        return furthestPageIndex >= pageCount - 1 ? .finished : .inProgress
    }

    /// Records the page the reader is on, and that it was read.
    func recordPage(_ index: Int) {
        recordPosition(index)
        recordRead(index)
    }

    /// Records where the reader is, to open there next time. Doesn't count
    /// the page as read: she may only have jumped there.
    func recordPosition(_ index: Int) {
        guard index >= 0, index < max(pageCount, 1) else { return }
        lastPageIndex = index
    }

    /// Records that a page was read, moving "furthest read" on if it's past it.
    func recordRead(_ index: Int) {
        guard index >= 0, index < max(pageCount, 1) else { return }
        furthestPageIndex = max(furthestPageIndex, index)
    }

    /// The page's printed label as remembered, else its number (1-based).
    func label(ofPage index: Int) -> String {
        pageLabels.indices.contains(index) && pageLabels.count == pageCount ? pageLabels[index] : String(index + 1)
    }

    /// What this PDF has on the library's Notes page: page notes, highlights
    /// with a note, and the summary.
    var notesCount: Int {
        pageNotes.count + highlights.count { !$0.note.isEmpty } + (summary.isEmpty ? 0 : 1)
    }

    /// Number of highlights of each kind, in `HighlightKind.allCases` order.
    var highlightCounts: [Int] {
        HighlightKind.allCases.map { kind in highlights.count { $0.kindRaw == kind.rawValue } }
    }

    var hasOpenQuestions: Bool {
        highlights.contains { $0.kindRaw == HighlightKind.question.rawValue }
    }
}

enum ReadingStatus: String, CaseIterable, Identifiable {
    case unread = "Unread"
    case inProgress = "In progress"
    case finished = "Finished"

    var id: String { rawValue }
}
