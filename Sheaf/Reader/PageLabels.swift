import PDFKit

/// Printed page numbers. Many PDFs number their pages the way the printed
/// book or journal does: "xii" in a preface, "245" in a journal article
/// that starts on page 233. Sheaf shows and cites those, and falls back to
/// counting pages (1, 2, 3…) when a PDF has none.
nonisolated enum PageLabels {
    /// The PDF's labels, one per page, or none when they're just 1, 2, 3…
    /// (PDFKit reports a page's number as its label when there are none.)
    static func read(from document: PDFDocument) -> [String] {
        cleaned((0..<document.pageCount).map { document.page(at: $0)?.label })
    }

    /// The labels to keep, from each page's label as PDFKit reports it.
    static func cleaned(_ reported: [String?]) -> [String] {
        let labels = reported.map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let isPlain = labels.enumerated().allSatisfy { index, label in label.isEmpty || label == String(index + 1) }
        guard !isPlain else { return [] }
        // A page without a label of its own shows its number.
        return labels.enumerated().map { index, label in label.isEmpty ? String(index + 1) : label }
    }

    /// The labels to show for a PDF: its own, or the ones remembered from
    /// before Sheaf saved highlights into it (saving loses them).
    static func labels(for document: PDFDocument, remembered: [String]) -> [String] {
        let own = read(from: document)
        if !own.isEmpty { return own }
        return remembered.count == document.pageCount ? remembered : []
    }

    /// The page (0-based) that what she typed in Go to Page names: a printed
    /// label first ("xii", "245"), then a plain page number. `nil` if none.
    static func pageIndex(for typed: String, labels: [String], pageCount: Int) -> Int? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let index = labels.firstIndex(where: { $0.compare(typed, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame }) {
            return index
        }
        guard let number = Int(typed), (1...max(pageCount, 1)).contains(number), number <= pageCount else { return nil }
        return number - 1
    }
}
