import AppKit
import UniformTypeIdentifiers

/// The Highlights and Notes pages as Markdown: exactly what the page shows,
/// grouped by PDF and then by color, cited the way Copy as Quote cites.
/// Notes and answers go under their highlight.
enum HighlightsMarkdown {
    /// `title` is the page's ("Highlights", "Notes"); `details` says what
    /// was shown, like "From “Thesis” · Question · Open questions only".
    static func export(title: String, details: String, sections: [HighlightSection]) -> String {
        let items = sections.flatMap(\.items)
        var lines = ["# \(title)", "", details, ""]
        for entry in HighlightList.pdfs(in: sections) {
            let mine = items.filter { $0.entry?.id == entry.id }
            lines.append("## \(entry.title)")
            lines.append("")
            if let collection = entry.collection {
                lines += ["Collection: \(collection.name)", ""]
            }
            if mine.contains(where: { if case .summary = $0 { true } else { false } }) {
                lines += ["### My summary", "", entry.summary, ""]
            }
            let highlights = mine.compactMap { if case .highlight(let record) = $0 { record } else { nil } }
            for kind in HighlightKind.allCases {
                let ofKind = highlights.filter { $0.kind == kind }
                    .sorted { HighlightList.readingOrder(.highlight($0), .highlight($1)) }
                guard !ofKind.isEmpty else { continue }
                lines += ["### \(kind.name)", ""]
                for record in ofKind {
                    lines.append("- " + record.quote)
                    if !record.note.isEmpty {
                        lines.append("  - " + continued(record.note, indent: "    "))
                    }
                    if record.isAnsweredQuestion {
                        lines.append("  - " + answer(record.answer, indent: "    "))
                    }
                }
                lines.append("")
            }
            let notes = mine.compactMap { if case .page(let note) = $0 { note } else { nil } }
                .sorted { ($0.pageIndex, $0.createdAt) < ($1.pageIndex, $1.createdAt) }
            if !notes.isEmpty {
                lines += ["### Page notes", ""]
                for note in notes {
                    let source = Citation.source(title: entry.title, page: note.displayPage)
                    lines.append("- " + continued(note.text, indent: "  ") + " (\(source))")
                }
                lines.append("")
            }
        }
        if items.isEmpty {
            lines.append("Nothing to export.")
        }
        return lines.joined(separator: "\n")
    }

    /// The answer of an answered question, as a list item's text:
    /// "Answer: what she found", or "Answered" when she wrote none.
    static func answer(_ answer: String, indent: String) -> String {
        answer.isEmpty ? "Answered" : "Answer: " + continued(answer, indent: indent)
    }

    /// Text over several lines, indented so Markdown keeps it in its list item.
    static func continued(_ text: String, indent: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: "\n" + indent)
    }
}

/// Saving Markdown text as a file, from the Highlights panel, the library's
/// Highlights and Notes pages, and File › Export as Markdown.
enum MarkdownFile {
    /// Asks where to save, then saves.
    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

extension Notification.Name {
    /// File › Export as Markdown with the library's Highlights or Notes page
    /// on screen: the page exports what it shows.
    static let sheafExportShownHighlights = Notification.Name("SheafExportShownHighlights")
}

extension ReaderModel {
    /// Export as Markdown, from the Highlights panel or the File menu.
    func exportMarkdown() {
        // A summary or note being typed is saved first, so it's in the file.
        NotificationCenter.default.post(name: .sheafFlushSaves, object: nil)
        MarkdownFile.save(markdownExport(), suggestedName: "\(title) highlights.md")
    }
}
