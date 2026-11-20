import Foundation
import SwiftData

/// A note on a whole page rather than on a highlight: for slides, diagrams
/// and scanned pages. Kept in Sheaf's library only, never in the PDF file.
/// A page has at most one.
@Model
final class PageNote {
    var id = UUID()
    /// 0-based.
    var pageIndex: Int
    /// The page's printed label, such as "xii" or "245", when the PDF has
    /// labels; empty when it doesn't, and the page number is shown instead.
    var pageLabel = ""
    var text: String
    var createdAt: Date
    var modifiedAt: Date
    var entry: LibraryEntry?

    init(pageIndex: Int, pageLabel: String = "", text: String, now: Date = .now) {
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.text = text
        self.createdAt = now
        self.modifiedAt = now
    }

    /// The page as she'd cite it: the printed label, else the page number.
    var displayPage: String {
        pageLabel.isEmpty ? entry?.label(ofPage: pageIndex) ?? String(pageIndex + 1) : pageLabel
    }
}

/// A page note's data, kept by Undo after the note is deleted.
struct PageNoteSnapshot {
    let id: UUID
    let pageIndex: Int
    let pageLabel: String
    let text: String
    let createdAt: Date
}

extension PageNoteSnapshot {
    init(_ note: PageNote) {
        self.init(id: note.id, pageIndex: note.pageIndex, pageLabel: note.pageLabel, text: note.text, createdAt: note.createdAt)
    }
}
