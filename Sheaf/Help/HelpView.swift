import SwiftUI

/// Help > Sheaf Help (⌘?): what the highlighters mean, how to use the main
/// features, and every keyboard shortcut. Topics on the left, as in Apple's
/// help; the page on the right reads top to bottom. It's Sheaf's own window
/// rather than an Apple Help Book, which would need a separately built bundle.
struct HelpView: View {
    static let windowID = "help"

    enum Topic: String, CaseIterable, Identifiable {
        case highlighters = "The four highlighters"
        case highlighting = "Highlighting"
        case notes = "Notes"
        case reading = "Reading"
        case finding = "Finding things"
        case shortcuts = "Keyboard shortcuts"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .highlighters: "paintpalette"
            case .highlighting: "highlighter"
            case .notes: "text.bubble"
            case .reading: "book"
            case .finding: "magnifyingglass"
            case .shortcuts: "command"
            }
        }
    }

    /// The topic at the top of the page. Clicking a topic scrolls to it, and
    /// scrolling updates it.
    @State private var topic: Topic? = .highlighters

    var body: some View {
        HStack(spacing: 0) {
            topicList
                .frame(width: 228)
                .background(Theme.sidebar)
            Hairline(axis: .vertical)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Topic.allCases) { topic in
                        // The room above each heading is part of its section,
                        // so a topic scrolled to the top isn't flush against the edge.
                        section(for: topic)
                            .padding(.top, 32)
                            .padding(.bottom, 8)
                            .id(topic)
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: 600, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
                // In a wide window the column stays centered in the space beside the topics.
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $topic, anchor: .top)
            .background(Theme.background)
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Theme.background)
    }

    private var topicList: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title: "Sheaf Help")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            ForEach(Topic.allCases) { item in
                let isSelected = topic == item
                Button {
                    withAnimation(Theme.motion) { topic = item }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage).frame(width: 16)
                        Text(item.rawValue).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.ink : Theme.inkSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(isSelected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Theme.control : .clear, lineWidth: 1))
                }
                .buttonStyle(.sheaf())
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func section(for topic: Topic) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(topic.rawValue)
                .font(Theme.display(22))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            switch topic {
            case .highlighters: highlighters
            case .highlighting: highlighting
            case .notes: notes
            case .reading: reading
            case .finding: finding
            case .shortcuts: shortcuts
            }
        }
    }

    // MARK: Topics

    private var highlighters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("Each highlighter color means something, so you can tell at a glance why you marked a passage. Later, the library gathers every question, or every piece of evidence, from all your PDFs.")
            VStack(spacing: 0) {
                ForEach(HighlightKind.allCases) { kind in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(kind.swatch)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.12), lineWidth: 1))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.name)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(kind.purpose)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.inkMuted)
                        }
                        Spacer()
                        KeyCap(String(kind.rawValue))
                            .accessibilityLabel("Key \(kind.rawValue)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    if kind != HighlightKind.allCases.last {
                        Hairline().padding(.leading, 48)
                    }
                }
            }
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        }
    }

    private var highlighting: some View {
        VStack(alignment: .leading, spacing: 14) {
            Step(number: 1, title: "Select, then press a number") {
                Text("Select text on the page, then press **1**, **2**, **3** or **4**. You can also click a highlighter in the toolbar, or use \u{2318}1 to \u{2318}4.")
            }
            Step(number: 2, title: "Or pick a highlighter first") {
                Text("With nothing selected, press a number or click a highlighter. Now everything you select is highlighted in that color. Press the number again, or click the highlighter again, to stop.")
            }
            Paragraph("To change a highlight\u{2019}s color or delete it, Control-click it in the Highlights panel. Changed your mind? \u{2318}Z undoes it.")
            Paragraph("Highlights are saved in Sheaf\u{2019}s library and inside the PDF itself, so Preview and other apps show them too. Password-protected and digitally signed PDFs are never changed; their highlights stay in Sheaf.")
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("Any highlight can have a note: a thought, a question to follow up, a reminder of why it matters.")
            Paragraph("Click a highlight on the page to write its note right there, change its color, copy it or delete it. Or, in the Highlights panel on the right, click **Add note** under a highlight. Type, then press Return to save, or Esc to cancel. \u{2325}\u{2318}N writes a note on the highlight you just made.")
            Paragraph("**Page notes** are for a whole page, like a slide, a diagram or a scanned page. Choose Highlight \u{203A} Add Page Note (\u{2303}\u{2318}N), or Control-click a page in the page strip. They\u{2019}re listed in the Highlights panel under their page.")
            Paragraph("**My summary**, at the top of the Highlights panel, is for what the whole PDF is about, in your own words.")
            Paragraph("Edit \u{203A} Copy as Quote (\u{21E7}\u{2318}C) copies a highlight, or the selected text, as \u{201C}the text\u{201D} (Title, p. 245), ready for an essay. You can also drag a highlight out of the Highlights panel into another app. Sheaf uses the page numbers printed in the PDF, like xii or 245, when it has them.")
            Paragraph("The **Notes** page in the library gathers your summaries, page notes and highlights with a note, from all your PDFs. To keep them outside Sheaf, click **Export as Markdown** at the bottom of the Highlights panel.")
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 18) {
            Subsection("Focus mode", "View \u{203A} Focus Mode (\u{21E7}\u{2318}F) hides the panels and fills the screen with the page. Press Esc or \u{21E7}\u{2318}F to come back.")
            Subsection("Two PDFs side by side", "Open a PDF in its own window: choose Open in New Window from the File menu, from the menu when you Control-click a PDF in the library, or from the menu under the PDF\u{2019}s title. In the library\u{2019}s list, Option-double-click or Option-Return does it too. A PDF is in one window at a time, and Move to Main Window puts it back. Closing its window closes the PDF. Window \u{203A} Merge All Windows keeps PDF windows together as tabs.")
            Subsection("Bookmarks", "Press \u{2318}D, or click the bookmark in the toolbar, to bookmark the page you\u{2019}re on. Bookmarked pages get a ribbon in the page strip and are listed at the top of the Highlights panel; click one to go there.")
            Subsection("Back", "When you jump somewhere (by following a link, or clicking the contents, a page, a search result or a highlight), a Back button appears at the bottom left of the page. Click it, or press \u{2318}[, to return to where you were. \u{2318}] goes forward again.")
            Subsection("Going to a page", "Go \u{203A} Go to Page (\u{2325}\u{2318}G) takes the page number printed in the PDF, like xii or 245, or a number counted from the first page.")
            Subsection("Reading progress", "The library counts a page as read when you read your way to it, by turning pages or scrolling, or once it has been on screen for ten seconds. Following a link to the references, or jumping to the last page, doesn\u{2019}t make a PDF Finished.")
            Subsection("Reading aloud", "Edit \u{203A} Speech \u{203A} Start Speaking reads the selected text aloud, or the page if nothing is selected. It uses the voice chosen in System Settings \u{203A} Accessibility \u{203A} Spoken Content.")
            Subsection("Page layout and dark pages", "The View menu and the toolbar set the page layout and size. Sheaf remembers them for the next PDF, and you\u{2019}ll find them in Settings (\u{2318},) too, with Dark Pages in Dark Mode.")
        }
    }

    private var finding: some View {
        VStack(alignment: .leading, spacing: 18) {
            Subsection("In a PDF", "\u{2318}F searches the PDF you\u{2019}re reading, and \u{2318}G and \u{21E7}\u{2318}G step through the matches. Select some text and press \u{2318}E to search for it.")
            Subsection("In the library", "\u{2318}K searches the whole library: titles, highlights and notes.")
            Subsection("In Spotlight", "Your highlights and notes are in Spotlight too. Search for words you highlighted or wrote in a note, and the result opens the PDF right at that highlight.")
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(ShortcutList.categories) { category in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: category.title)
                    VStack(spacing: 0) {
                        ForEach(category.shortcuts) { shortcut in
                            HStack(spacing: 12) {
                                Text(shortcut.action)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink)
                                Spacer(minLength: 12)
                                HStack(spacing: 6) {
                                    ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { index, keys in
                                        if index > 0 {
                                            Text("or")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(Theme.inkMuted)
                                        }
                                        KeyCap(keys)
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .accessibilityElement(children: .combine)
                            if shortcut.id != category.shortcuts.last?.id {
                                Hairline().padding(.horizontal, 14)
                            }
                        }
                    }
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
                }
            }
        }
    }
}

/// A short heading and its paragraph, inside a topic.
private struct Subsection: View {
    let title: String
    let text: String

    init(_ title: String, _ text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Paragraph(text)
        }
    }
}

/// Body text in the Help window, kept to a comfortable line length.
private struct Paragraph: View {
    let text: LocalizedStringKey

    init(_ text: String) {
        self.text = LocalizedStringKey(text)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.inkSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            // About 75 characters a line; the tables may use the full column.
            .frame(maxWidth: 540, alignment: .leading)
    }
}

/// A numbered step, for the two ways to highlight.
private struct Step<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(String(number))
                .font(Theme.display(13))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 22, height: 22)
                .background(Theme.accent, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                content
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.inkSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 506, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Keys drawn like a key on the keyboard, as in the shortcut table.
private struct KeyCap: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 22)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.control, lineWidth: 1))
            .fixedSize()
    }
}
