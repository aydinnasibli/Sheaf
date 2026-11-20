import AppKit
import UniformTypeIdentifiers

/// The Highlights and Notes pages as Markdown: exactly what the page shows,
/// in the same order and under the same headings (a PDF's when grouped by
/// PDF, "Summaries" and "Notes" on the Notes page), cited the way Copy as
/// Quote cites. Each highlight says its color, unless all of them are one
/// color; notes and answers go under their highlight.
enum HighlightsMarkdown {
    /// `title` is the page's ("Highlights", "Notes"); `details` says what
    /// was shown, like "From “Thesis” · Question · Open questions only".
    static func export(title: String, details: String, sections: [HighlightSection]) -> String {
        let items = sections.flatMap(\.items)
        let showsColors = Set(sections.flatMap(\.highlights).map(\.kind)).count > 1
        var lines = ["# \(title)", "", details, ""]
        for section in sections {
            if let entry = section.entry {
                lines += ["## \(entry.title)", ""]
                if let collection = entry.collection {
                    lines += ["Collection: \(collection.name)", ""]
                }
            } else if let heading = section.title {
                lines += ["## \(heading)", ""]
            }
            // A summary heads its PDF's group; elsewhere it's an item like the others.
            var list: [String] = []
            for item in section.items {
                switch item {
                case .summary(let entry) where section.entry != nil:
                    lines += ["**My summary:** " + entry.summary, ""]
                case .summary(let entry):
                    list.append("- **\(entry.title):** " + continued(entry.summary, indent: "  "))
                case .highlight(let record):
                    let color = showsColors ? "\(record.kind.name): " : ""
                    list.append("- " + color + record.quote)
                    if !record.note.isEmpty {
                        list.append("  - " + continued(record.note, indent: "    "))
                    }
                    if record.isAnsweredQuestion {
                        list.append("  - " + answer(record.answer, indent: "    "))
                    }
                case .page(let note):
                    let source = Citation.source(title: note.entry?.title ?? "PDF", page: note.displayPage)
                    list.append("- Page note: " + continued(note.text, indent: "  ") + " (\(source))")
                }
            }
            if !list.isEmpty { lines += list + [""] }
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
