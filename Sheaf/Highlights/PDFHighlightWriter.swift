import AppKit
import PDFKit

/// Writes Sheaf's highlights into a PDF file, away from the main thread.
///
/// Saving a long PDF can take several seconds, so it works on its own copy
/// of the document: it reads the file, replaces the Sheaf highlights with
/// the current set, and writes it back. Highlights from other apps are kept,
/// and so are Sheaf highlights the library doesn't know about (the file may
/// have been highlighted before it was removed from the library, say).
///
/// The new file is checked before it replaces the old one, and replaces it
/// in one step, so a failed save leaves the file as it was.
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

    /// Writes `highlights` into the PDF at `url`.
    ///
    /// Only the Sheaf highlights in `highlights` (written again) and in
    /// `removedIDs` (deleted in Sheaf) are taken out of the file first; any
    /// other Sheaf highlight in it stays. With an `archive`, a copy of the
    /// file as it was is kept the first time Sheaf rewrites it.
    static func write(
        _ highlights: [HighlightSnapshot],
        removing removedIDs: Set<UUID> = [],
        to url: URL,
        keepingOriginalIn archive: OriginalPDFArchive? = nil
    ) -> Outcome {
        var coordinationError: NSError?
        var outcome = Outcome.failed("The file couldn\u{2019}t be written.")
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            outcome = writeNow(highlights, removing: removedIDs, to: target, archive: archive)
        }
        if let coordinationError {
            return .failed(coordinationError.localizedDescription)
        }
        return outcome
    }

    private static func writeNow(
        _ highlights: [HighlightSnapshot], removing removedIDs: Set<UUID>, to url: URL, archive: OriginalPDFArchive?
    ) -> Outcome {
        guard let original = try? Data(contentsOf: url), let document = PDFDocument(data: original) else {
            return .failed("The file couldn\u{2019}t be read.")
        }
        if document.isEncrypted { return .passwordProtected }
        if isSigned(document) { return .signed }
        let pageCount = document.pageCount

        let rewritten = Set(highlights.map(\.id)).union(removedIDs)
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                if let id = id(of: annotation), rewritten.contains(id) {
                    page.removeAnnotation(annotation)
                }
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
        guard isComplete(data, pageCount: pageCount, highlights: highlights) else {
            return .failed("The new version of the file didn\u{2019}t check out, so the file was left as it was.")
        }
        archive?.keepCopy(of: original, fileName: url.lastPathComponent)
        do {
            try SafeFileWriter.replace(url, with: data)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Whether `data` is a PDF that opens again, with all `pageCount` pages
    /// and every highlight just written. Checked before it replaces the file.
    static func isComplete(_ data: Data, pageCount: Int, highlights: [HighlightSnapshot]) -> Bool {
        guard let check = PDFDocument(data: data), check.pageCount == pageCount else { return false }
        let written = highlights.filter { (0..<pageCount).contains($0.pageIndex) && !$0.rects.isEmpty }
        for (index, onPage) in Dictionary(grouping: written, by: \.pageIndex) {
            guard let page = check.page(at: index) else { return false }
            let present = Set(page.annotations.compactMap(id(of:)))
            guard onPage.allSatisfy({ present.contains($0.id) }) else { return false }
        }
        return true
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
