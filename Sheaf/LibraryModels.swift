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
    /// A small image of the first page, as PNG.
    @Attribute(.externalStorage) var cover: Data?
    var collection: PDFCollection?

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

    /// Records the page the reader is on.
    func recordPage(_ index: Int) {
        guard index >= 0, index < max(pageCount, 1) else { return }
        lastPageIndex = index
        furthestPageIndex = max(furthestPageIndex, index)
    }
}

enum ReadingStatus: String, CaseIterable, Identifiable {
    case unread = "Unread"
    case inProgress = "In progress"
    case finished = "Finished"

    var id: String { rawValue }
}

/// A user-made group of PDFs, shown in the library sidebar.
@Model
final class PDFCollection {
    var id = UUID()
    var name: String
    /// Index into `Theme.collectionColors`.
    var colorIndex: Int
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \LibraryEntry.collection)
    var items: [LibraryEntry] = []

    init(name: String, colorIndex: Int, now: Date = .now) {
        self.name = name
        self.colorIndex = colorIndex
        self.createdAt = now
    }
}
