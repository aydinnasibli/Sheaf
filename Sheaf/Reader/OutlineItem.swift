import AppKit
import Observation
import PDFKit

/// One entry in the PDF's table of contents.
struct OutlineItem: Identifiable {
    let id: ObjectIdentifier
    let title: String
    let destination: PDFDestination?
    /// `nil` for entries with no sub-entries, as `List(children:)` expects.
    let children: [OutlineItem]?
    /// Keeps the PDFKit object alive so `id` stays unique.
    private let outline: PDFOutline

    init(_ outline: PDFOutline) {
        self.outline = outline
        id = ObjectIdentifier(outline)
        title = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        let children = Self.items(under: outline)
        self.children = children.isEmpty ? nil : children
    }

    static func items(under parent: PDFOutline?) -> [OutlineItem] {
        guard let parent else { return [] }
        return (0..<parent.numberOfChildren).compactMap { parent.child(at: $0) }.map(OutlineItem.init)
    }
}

/// One line in the Contents list: a table-of-contents entry with its depth
/// and the page it starts on.
struct OutlineRow: Identifiable {
    /// Position in the list.
    let id: Int
    let title: String
    let depth: Int
    let pageIndex: Int?
    let destination: PDFDestination?

    static func flatten(_ items: [OutlineItem], in document: PDFDocument) -> [OutlineRow] {
        var rows: [OutlineRow] = []
        func visit(_ items: [OutlineItem], depth: Int) {
            for item in items {
                rows.append(OutlineRow(
                    id: rows.count,
                    title: item.title.isEmpty ? "Untitled" : item.title,
                    depth: depth,
                    pageIndex: item.destination?.page.map { document.index(for: $0) },
                    destination: item.destination
                ))
                visit(item.children ?? [], depth: depth + 1)
            }
        }
        visit(items, depth: 0)
        return rows
    }
}
