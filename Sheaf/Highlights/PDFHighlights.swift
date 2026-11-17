import AppKit
import PDFKit

/// Adds, updates and removes Sheaf's highlights in the PDF that's on screen.
/// (Writing them into the file happens in `PDFHighlightWriter`.)
///
/// Each line of a highlight is its own annotation, tagged with a `/SheafID`
/// entry `sheaf-<record id>-<line>` so Sheaf can find it again.
enum PDFHighlights {
    static func add(_ record: HighlightRecord, to document: PDFDocument) {
        add(HighlightSnapshot(record), to: document)
    }

    static func add(_ snapshot: HighlightSnapshot, to document: PDFDocument) {
        guard let page = document.page(at: snapshot.pageIndex) else { return }
        for annotation in PDFHighlightWriter.makeAnnotations(for: snapshot) {
            page.addAnnotation(annotation)
        }
    }

    static func remove(_ id: UUID, from document: PDFDocument) {
        for (page, annotation) in annotations(for: id, in: document) {
            page.removeAnnotation(annotation)
        }
    }

    static func update(_ record: HighlightRecord, in document: PDFDocument) {
        for (_, annotation) in annotations(for: record.id, in: document) {
            annotation.color = record.kind.pageColor
            annotation.contents = record.note.isEmpty ? nil : record.note
        }
    }

    /// IDs of the Sheaf highlights already in the PDF.
    static func ids(in document: PDFDocument) -> Set<UUID> {
        var ids = Set<UUID>()
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let id = id(of: annotation) { ids.insert(id) }
            }
        }
        return ids
    }

    /// Adds any highlights from the index that the PDF is missing, for
    /// example after an earlier save failed. Returns how many were added.
    @discardableResult
    static func restoreMissing(_ records: [HighlightRecord], in document: PDFDocument) -> Int {
        let present = ids(in: document)
        let missing = records.filter { !present.contains($0.id) }
        for record in missing { add(record, to: document) }
        return missing.count
    }

    static func id(of annotation: PDFAnnotation) -> UUID? {
        PDFHighlightWriter.id(of: annotation)
    }

    private static func annotations(for id: UUID, in document: PDFDocument) -> [(PDFPage, PDFAnnotation)] {
        var found: [(PDFPage, PDFAnnotation)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where self.id(of: annotation) == id {
                found.append((page, annotation))
            }
        }
        return found
    }
}
