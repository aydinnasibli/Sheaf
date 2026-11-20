import CoreGraphics
import Foundation
import SwiftData

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
    /// The page's printed label, such as "xii" or "245", when the PDF has
    /// labels. Kept here so the library can cite the page without opening
    /// the PDF. Empty for PDFs without labels and older highlights.
    var pageLabel = ""
    /// A Question she has answered. Kept in Sheaf's library only, like page
    /// notes: nothing about answers is written into the PDF.
    var isAnswered = false
    /// What she found out, in her own words. May be empty: a question can be
    /// marked answered without writing anything.
    var answer = ""
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

    /// The left edge of its first line, for ordering highlights at the same height.
    var left: Double { Double(rects.first?.minX ?? 0) }

    /// A Question not answered yet: what "Open questions" counts. Answers
    /// only mean something on Questions, so another color is never open
    /// or answered (and changing it back to Question brings its answer back).
    var isOpenQuestion: Bool { kindRaw == HighlightKind.question.rawValue && !isAnswered }

    var isAnsweredQuestion: Bool { kindRaw == HighlightKind.question.rawValue && isAnswered }
}
