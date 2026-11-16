import AppKit
import PDFKit

/// Writes Sheaf's highlights into a PDF as standard highlight annotations,
/// so they also appear in Preview and other PDF apps.
///
/// Each line of a highlight is its own annotation. Every annotation carries
/// a `/SheafID` entry, `sheaf-<record id>-<line>`, which is how Sheaf finds
/// its own highlights again when the file is reopened. (PDFKit drops the
/// standard "NM" name field when saving, but keeps custom entries; other
/// PDF apps ignore entries they don't know.)
enum PDFHighlights {
    static let prefix = "sheaf-"
    static let idKey = PDFAnnotationKey(rawValue: "/SheafID")

    static func add(_ record: HighlightRecord, to document: PDFDocument) {
        guard let page = document.page(at: record.pageIndex) else { return }
        for (line, rect) in record.rects.enumerated() {
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = record.kind.pageColor
            annotation.contents = record.note.isEmpty ? nil : record.note
            annotation.userName = "Sheaf"
            annotation.setValue(name(for: record.id, line: line), forAnnotationKey: idKey)
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

    /// Adds any highlights from the index that the file is missing, for
    /// example after an earlier save failed. Returns how many were added.
    @discardableResult
    static func restoreMissing(_ records: [HighlightRecord], in document: PDFDocument) -> Int {
        let present = ids(in: document)
        let missing = records.filter { !present.contains($0.id) }
        for record in missing { add(record, to: document) }
        return missing.count
    }

    // MARK: Helpers

    static func name(for id: UUID, line: Int) -> String {
        "\(prefix)\(id.uuidString)-\(line)"
    }

    static func id(of annotation: PDFAnnotation) -> UUID? {
        guard let name = annotation.value(forAnnotationKey: idKey) as? String, name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        return UUID(uuidString: String(rest.prefix(36)))
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
