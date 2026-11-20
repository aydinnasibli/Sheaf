import AppKit
import PDFKit

/// Reads Sheaf's highlights back out of a PDF file, so highlights saved into
/// a file are never forgotten: when the file was removed from the library
/// and opened again, or the library entry is new, say.
nonisolated enum PDFHighlightImport {
    /// A Sheaf highlight found in a file.
    struct Found: Sendable {
        let id: UUID
        let pageIndex: Int
        let text: String
        let note: String
        let rects: [CGRect]
        /// The color on the page, as 0xRRGGBB. Another app may have changed
        /// it a little, so the library picks the nearest highlighter.
        let colorHex: UInt32
        let createdAt: Date
    }

    /// The Sheaf highlights in `document` whose IDs aren't in `known`. Each
    /// line of a highlight is its own annotation, tagged
    /// `sheaf-<id>-<line>`; the lines are put back together in order.
    static func highlights(in document: PDFDocument, excluding known: Set<UUID>) -> [Found] {
        var lines: [UUID: [(line: Int, pageIndex: Int, annotation: PDFAnnotation)]] = [:]
        var order: [UUID] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                guard let (id, line) = tag(of: annotation), !known.contains(id) else { continue }
                if lines[id] == nil { order.append(id) }
                lines[id, default: []].append((line, index, annotation))
            }
        }
        return order.compactMap { id in
            guard let parts = lines[id]?.sorted(by: { $0.line < $1.line }), let first = parts.first,
                  let page = document.page(at: first.pageIndex)
            else { return nil }
            // A highlight is on one page; Sheaf makes one per page.
            let onPage = parts.filter { $0.pageIndex == first.pageIndex }.map(\.annotation)
            let text = onPage
                .compactMap { page.selection(for: $0.bounds)?.string }
                .map { $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return Found(
                id: id,
                pageIndex: first.pageIndex,
                text: text,
                note: onPage.lazy.compactMap(\.contents).first { !$0.isEmpty } ?? "",
                rects: onPage.map(\.bounds),
                colorHex: hex(of: first.annotation.color),
                createdAt: first.annotation.modificationDate ?? .now
            )
        }
    }

    /// The record ID and line number in an annotation's `/SheafID` tag.
    static func tag(of annotation: PDFAnnotation) -> (id: UUID, line: Int)? {
        guard let id = PDFHighlightWriter.id(of: annotation),
              let name = annotation.value(forAnnotationKey: PDFHighlightWriter.idKey) as? String
        else { return nil }
        let line = name.split(separator: "-").last.flatMap { Int($0) } ?? 0
        return (id, line)
    }

    static func hex(of color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
    }
}

extension HighlightKind {
    /// The highlighter whose page color is closest to `hex` (0xRRGGBB).
    static func nearest(toColorHex hex: UInt32) -> HighlightKind {
        func distance(_ a: UInt32, _ b: UInt32) -> Int {
            [16, 8, 0].reduce(0) { sum, shift in
                let difference = Int((a >> shift) & 0xFF) - Int((b >> shift) & 0xFF)
                return sum + difference * difference
            }
        }
        return allCases.min { distance($0.pageColorHex, hex) < distance($1.pageColorHex, hex) } ?? .keyIdea
    }
}
