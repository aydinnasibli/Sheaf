import AppKit
import PDFKit

/// Writes Sheaf's highlights into a PDF file, away from the main thread.
///
/// Saving a long PDF can take several seconds, so it works on its own copy
/// of the document: it reads the file, replaces the Sheaf highlights with
/// the current set, and writes it back. Highlights from other apps are kept.
nonisolated enum PDFHighlightWriter {
    enum Outcome: Sendable, Equatable {
        case saved
        /// The PDF is digitally signed; rewriting it would break the signature.
        case signed
        /// The PDF is password-protected; rewriting it would remove the password.
        case passwordProtected
        case failed(String)
    }

    /// The custom annotation entry that marks Sheaf's highlights. (PDFKit
    /// drops the standard "NM" name when saving but keeps custom entries.)
    static let idKey = PDFAnnotationKey(rawValue: "/SheafID")
    static let prefix = "sheaf-"

    static func write(_ highlights: [HighlightSnapshot], to url: URL) -> Outcome {
        var coordinationError: NSError?
        var outcome = Outcome.failed("The file couldn\u{2019}t be written.")
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            outcome = writeNow(highlights, to: target)
        }
        if let coordinationError {
            return .failed(coordinationError.localizedDescription)
        }
        return outcome
    }

    private static func writeNow(_ highlights: [HighlightSnapshot], to url: URL) -> Outcome {
        // Read the whole file into memory first: the file is then rewritten
        // in place (Sheaf may write the file but not its folder).
        guard let original = try? Data(contentsOf: url), let document = PDFDocument(data: original) else {
            return .failed("The file couldn\u{2019}t be read.")
        }
        if document.isEncrypted { return .passwordProtected }
        if isSigned(document) { return .signed }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where id(of: annotation) != nil {
                page.removeAnnotation(annotation)
            }
        }
        for highlight in highlights {
            guard let page = document.page(at: highlight.pageIndex) else { continue }
            for annotation in makeAnnotations(for: highlight) {
                page.addAnnotation(annotation)
            }
        }

        guard let data = document.dataRepresentation() else {
            return .failed("PDFKit couldn\u{2019}t save the file.")
        }
        do {
            try data.write(to: url)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// One highlight annotation per line of the highlight.
    static func makeAnnotations(for highlight: HighlightSnapshot) -> [PDFAnnotation] {
        let color = NSColor(
            srgbRed: CGFloat((highlight.colorHex >> 16) & 0xFF) / 255,
            green: CGFloat((highlight.colorHex >> 8) & 0xFF) / 255,
            blue: CGFloat(highlight.colorHex & 0xFF) / 255,
            alpha: 1
        )
        return highlight.rects.enumerated().map { line, rect in
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = color
            annotation.contents = highlight.note.isEmpty ? nil : highlight.note
            annotation.userName = "Sheaf"
            // Highlights print, in Sheaf and in other apps (like Preview's).
            annotation.shouldPrint = true
            annotation.setValue("\(prefix)\(highlight.id.uuidString)-\(line)", forAnnotationKey: idKey)
            return annotation
        }
    }

    static func id(of annotation: PDFAnnotation) -> UUID? {
        guard let name = annotation.value(forAnnotationKey: idKey) as? String, name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).prefix(36)))
    }

    /// Whether the PDF has signature fields. Rewriting a signed PDF
    /// invalidates its signatures, so Sheaf leaves those files alone.
    static func isSigned(_ document: PDFDocument) -> Bool {
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.widgetFieldType == .signature {
                return true
            }
        }
        return false
    }
}
