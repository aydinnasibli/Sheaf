import AppKit
import PDFKit

/// A highlight's data, copied out of SwiftData so it can be written into a
/// PDF on a background thread (and restored by Undo).
nonisolated struct HighlightSnapshot: Sendable {
    let id: UUID
    let pageIndex: Int
    let kindRaw: Int
    let text: String
    let note: String
    let rects: [CGRect]
    let createdAt: Date
    /// The highlight color on the page, as 0xRRGGBB.
    let colorHex: UInt32
}

extension HighlightSnapshot {
    init(_ record: HighlightRecord) {
        self.init(
            id: record.id,
            pageIndex: record.pageIndex,
            kindRaw: record.kindRaw,
            text: record.text,
            note: record.note,
            rects: record.rects,
            createdAt: record.createdAt,
            colorHex: record.kind.pageColorHex
        )
    }
}
