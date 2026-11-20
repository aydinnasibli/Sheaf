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
    /// Libraries from before `readPages`: every page up to this one
    /// (0-based) counts as read, as it did then. No longer moved on: a page
    /// read now goes into `readPages`. 0 counts nothing, since it was also
    /// where a PDF never opened started.
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
    /// they differ from plain page numbers. Remembered because older versions
    /// of Sheaf (and other apps) lost them when saving highlights into a PDF;
    /// Sheaf now puts them back into the file when it saves.
    var pageLabels: [String] = []
    /// The pages read (0-based), in order: drives the "Read" percentage and
    /// "Finished". A page jumped to and left on screen a while counts on
    /// its own, without the pages before it.
    var readPages: [Int] = []
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

    /// How much has been read, from 0 to 1: the share of its pages read.
    /// A PDF never opened has read nothing.
    var progress: Double {
        guard pageCount > 0 else { return 0 }
        return min(1, Double(readPageCount) / Double(pageCount))
    }

    /// How many of its pages have been read.
    var readPageCount: Int {
        let legacy = legacyReadThrough
        let later = readPages.count { $0 > legacy && $0 < pageCount }
        return later + min(legacy + 1, pageCount)
    }

    var readingStatus: ReadingStatus {
        let read = readPageCount
        if read == 0 { return lastPageIndex == 0 ? .unread : .inProgress }
        return read >= pageCount ? .finished : .inProgress
    }

    /// Whether a page has been read.
    func hasRead(_ index: Int) -> Bool {
        index <= legacyReadThrough || readPages.contains(index)
    }

    /// The last page of the pages read the old way, from the first page on
    /// (see `furthestPageIndex`), or -1 when there are none.
    private var legacyReadThrough: Int {
        furthestPageIndex > 0 ? furthestPageIndex : -1
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

    /// Records that a page was read. The pages before it aren't: she may
    /// have jumped there.
    func recordRead(_ index: Int) {
        recordRead([index])
    }

    /// Records that these pages were read.
    func recordRead(_ pages: some Sequence<Int>) {
        let new = pages.filter { $0 >= 0 && $0 < max(pageCount, 1) && !hasRead($0) }
        guard !new.isEmpty else { return }
        readPages = Set(readPages).union(new).sorted()
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

    /// Questions not answered yet. Answering one takes it off the count.
    var openQuestionCount: Int {
        highlights.count(where: \.isOpenQuestion)
    }

    var hasOpenQuestions: Bool {
        highlights.contains(where: \.isOpenQuestion)
    }
}

enum ReadingStatus: String, CaseIterable, Identifiable {
    case unread = "Unread"
    case inProgress = "In progress"
    case finished = "Finished"

    var id: String { rawValue }
}
