import AppKit
import PDFKit

extension PDFHighlights {
    /// Gives the Sheaf highlights in a PDF that was just opened the colors
    /// and notes the library has for them, in one pass over its pages. They
    /// differ when a highlight was changed on the library's Highlights page
    /// while the PDF was closed; the next save writes the change into the
    /// file, and this makes the pages show it meanwhile.
    static func match(_ document: PDFDocument, to records: [HighlightRecord]) {
        guard !records.isEmpty else { return }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let id = id(of: annotation), let record = byID[id] else { continue }
                annotation.color = record.kind.pageColor
                annotation.contents = record.note.isEmpty ? nil : record.note
            }
        }
    }
}
