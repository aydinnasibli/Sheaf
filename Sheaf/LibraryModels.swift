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
    /// A small image of the first page, as PNG.
    @Attribute(.externalStorage) var cover: Data?
    var collection: PDFCollection?
    @Relationship(deleteRule: .cascade, inverse: \HighlightRecord.entry)
    var highlights: [HighlightRecord] = []

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

    /// Number of highlights of each kind, in `HighlightKind.allCases` order.
    var highlightCounts: [Int] {
        HighlightKind.allCases.map { kind in highlights.count { $0.kindRaw == kind.rawValue } }
    }

    var hasOpenQuestions: Bool {
        highlights.contains { $0.kindRaw == HighlightKind.question.rawValue }
    }
}

/// A highlight in Sheaf's own index. The same highlight is also written
/// into the PDF as a standard annotation, so it shows in Preview too.
@Model
final class HighlightRecord {
    var id = UUID()
    var pageIndex: Int
    var kindRaw: Int
    var text: String
    var note = ""
    var createdAt: Date
    /// One rectangle per line, in page coordinates: x, y, width, height, …
    var rectValues: [Double]
    var entry: LibraryEntry?

    init(pageIndex: Int, kind: HighlightKind, text: String, rects: [CGRect], now: Date = .now) {
        self.pageIndex = pageIndex
        self.kindRaw = kind.rawValue
        self.text = text
        self.createdAt = now
        self.rectValues = rects.flatMap { [$0.origin.x, $0.origin.y, $0.width, $0.height] }
    }

    var kind: HighlightKind {
        get { HighlightKind(rawValue: kindRaw) ?? .keyIdea }
        set { kindRaw = newValue.rawValue }
    }

    var rects: [CGRect] {
        stride(from: 0, to: rectValues.count - 3, by: 4).map {
            CGRect(x: rectValues[$0], y: rectValues[$0 + 1], width: rectValues[$0 + 2], height: rectValues[$0 + 3])
        }
    }

    /// The top of the highlight in page coordinates (PDF y grows upward).
    var top: Double { Double(rects.map(\.maxY).max() ?? 0) }
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
