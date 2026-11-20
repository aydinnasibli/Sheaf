import AppKit
import Foundation

/// How Sheaf cites what she highlighted: “highlighted text” (Title, p. 245).
/// Copy as Quote, dragging a highlight out of Sheaf and the Markdown export
/// all use it, so a quote looks the same wherever it ends up.
nonisolated enum Citation {
    /// “text” (Title, p. 245), on one line.
    static func quote(_ text: String, title: String, page: String) -> String {
        "\u{201C}\(oneLine(text))\u{201D} (\(source(title: title, page: page)))"
    }

    /// “text” (Title, pp. 12–13), for text that runs over to the next page.
    static func quote(_ text: String, title: String, firstPage: String, lastPage: String) -> String {
        guard firstPage != lastPage else { return quote(text, title: title, page: firstPage) }
        return "\u{201C}\(oneLine(text))\u{201D} (\(title), pp. \(firstPage)\u{2013}\(lastPage))"
    }

    /// "Title, p. 245": what goes in the parentheses.
    static func source(title: String, page: String) -> String {
        "\(title), p. \(page)"
    }

    /// PDF text keeps the page's line breaks; a quote reads better without them.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Puts text on the clipboard, as Copy does.
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Text for dragging out of Sheaf, into Pages, Word, Notes or Mail.
    static func dragItem(_ text: String) -> NSItemProvider {
        NSItemProvider(object: text as NSString)
    }
}

extension HighlightRecord {
    /// The page as she'd cite it: the printed label ("xii", "245") when the
    /// PDF has one, else the page number. Highlights made before Sheaf kept
    /// labels use the PDF's labels if it has been opened since.
    var displayPage: String {
        pageLabel.isEmpty ? entry?.label(ofPage: pageIndex) ?? String(pageIndex + 1) : pageLabel
    }

    /// “highlighted text” (Title, p. 245)
    var quote: String {
        Citation.quote(text, title: entry?.title ?? "PDF", page: displayPage)
    }
}
