import Foundation
import PDFKit

/// What Sheaf needs to know about a PDF's pages as it opens: their printed
/// labels, and the Sheaf highlights already in the file. Found in one pass
/// over the pages while the PDF is read in the background, so the main
/// thread doesn't go through a long book page by page again.
nonisolated struct OpeningScan: Sendable, Equatable {
    /// The PDF's own printed page labels, as `PageLabels.read` gives them.
    let labels: [String]
    /// The IDs of the Sheaf highlights in the file.
    let highlightIDs: Set<UUID>

    init(labels: [String], highlightIDs: Set<UUID>) {
        self.labels = labels
        self.highlightIDs = highlightIDs
    }

    /// Goes through the pages of a PDF that only this thread is using.
    init(_ document: PDFDocument) {
        var labels: [String?] = []
        var ids = Set<UUID>()
        for index in 0..<document.pageCount {
            autoreleasepool {
                let page = document.page(at: index)
                labels.append(page?.label)
                for annotation in page?.annotations ?? [] {
                    if let id = PDFHighlightWriter.id(of: annotation) { ids.insert(id) }
                }
            }
        }
        self.init(labels: PageLabels.cleaned(labels), highlightIDs: ids)
    }

    /// Whether the file already has every highlight in `current` and none
    /// of those deleted in Sheaf (`removedIDs`): then there's nothing to
    /// bring up to date (see `PDFHighlights.bringUpToDate`).
    func isUpToDate(with current: Set<UUID>, removedIDs: [UUID]) -> Bool {
        current.isSubset(of: highlightIDs) && Set(removedIDs).subtracting(current).isDisjoint(with: highlightIDs)
    }
}
