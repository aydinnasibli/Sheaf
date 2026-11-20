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
        case scanned = "Scanned PDFs"
        case notes = "Notes"
        case pageNotes = "Page notes, summaries"
        case answering = "Answering questions"
        case review = "Review flashcards"
        case reading = "Reading"
        case sideBySide = "Two PDFs side by side"
        case library = "Your library"
        case finding = "Finding things"
        case shortcuts = "Keyboard shortcuts"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .highlighters: "paintpalette"
            case .highlighting: "highlighter"
            case .scanned: "doc.viewfinder"
            case .notes: "text.bubble"
            case .pageNotes: "note.text"
            case .answering: "checkmark.circle"
            case .review: "rectangle.on.rectangle.angled"
            case .reading: "book"
            case .sideBySide: "rectangle.split.2x1"
            case .library: "books.vertical"
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

    /// Scrolls when the window is too short for every topic.
    private var topicList: some View {
        ScrollView {
            topics
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var topics: some View {
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
            case .scanned: scanned
            case .notes: notes
            case .pageNotes: pageNotes
            case .answering: answering
            case .review: review
            case .reading: reading
            case .sideBySide: sideBySide
            case .library: library
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
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.swatchEdge, lineWidth: 1))
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
                Text("With nothing selected, press a number or click a highlighter. Now everything you select is highlighted in that color. To put the highlighter down, press the number again, click it again, or press Esc.")
            }
            Paragraph("Click a highlight on the page to change its color, copy it or delete it. In the Highlights panel, Control-click a highlight for the same things. Changed your mind? \u{2318}Z undoes it.")
            Paragraph("Highlights are saved in Sheaf\u{2019}s library and inside the PDF itself, so Preview and other apps show them too. Saving keeps the PDF\u{2019}s printed page numbers, language and viewing settings.")
            Paragraph("Some PDFs could be harmed by rewriting them, so Sheaf never changes them: ones that are password-protected, digitally signed or certified, or that have attached files, layers you can show or hide, sound, video or 3D, a portfolio of files or an XFA form. Their highlights stay in Sheaf\u{2019}s library, and the Highlights panel says why.")
        }
    }

    private var scanned: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("Some PDFs are scanned pages: pictures of text, with nothing to select. To highlight there, pick a highlighter and drag a box around what you want. Sheaf reads the words inside the box off the picture, so the highlight has its text.")
            Paragraph("On any page, hold Option and drag where there\u{2019}s no text, around a figure, a table or an equation, to highlight that area. On text, Option-drag selects text as usual. With no highlighter picked, the box is a Key idea.")
            Paragraph("Once you\u{2019}ve opened a scanned PDF, Sheaf reads the text of its pages in the background. Then \u{2318}F finds words on them, and so does the library\u{2019}s search.")
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("Any highlight can have a note: a thought, a question to follow up, a reminder of why it matters.")
            Paragraph("Click a highlight on the page to write its note right there. Or, in the Highlights panel on the right, click **Add Note** under a highlight. Type, then press Return to save, or Esc to cancel. \u{2325}\u{2318}N writes a note on the highlight you just made.")
            Paragraph("Edit \u{203A} Copy as Quote (\u{21E7}\u{2318}C) copies a highlight, or the selected text, as \u{201C}the text\u{201D} (Title, p. 245), ready for an essay. You can also drag a highlight out of the Highlights panel into another app. Sheaf uses the page numbers printed in the PDF, like xii or 245, when it has them.")
            Paragraph("As you type, the Edit menu\u{2019}s Spelling and Grammar checks your spelling, and Substitutions turns on smart quotes and dashes.")
            Paragraph("For revising, the library\u{2019}s **Highlights** page shows every highlight from all your PDFs, a collection or one PDF, newest first or in reading order, grouped by PDF if you like. Point at a card to add a note, change its color or delete it (\u{2318}Z brings it back). **Export as Markdown\u{2026}** saves exactly what the page shows, in the same order and groups.")
            Paragraph("To keep one PDF\u{2019}s summary, highlights and notes in a file of their own, click **Export as Markdown\u{2026}** at the bottom of its Highlights panel.")
        }
    }

    private var pageNotes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("**Page notes** are for a whole page, like a slide, a diagram or a scanned page. Choose Highlight \u{203A} Add Page Note (\u{2303}\u{2318}N), or Control-click a page in the page strip. A page with a note has a note icon beside its thumbnail, and the note is in the Highlights panel under its page; click it to edit it.")
            Paragraph("**My summary**, at the top of the Highlights panel, is for what the whole PDF is about, in your own words. Return starts a new line, and it\u{2019}s saved when you click elsewhere. Click **My summary** to fold it away.")
            Paragraph("The library\u{2019}s **Notes** page gathers your summaries, page notes and highlights with a note, from all your PDFs. Click one to open its PDF there. **Export as Markdown\u{2026}** saves what the page shows.")
            Paragraph("Page notes and summaries are kept in Sheaf\u{2019}s library, not in the PDF file, and Spotlight finds them.")
        }
    }

    private var answering: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("A Question highlight is something to find out. Once you have, click **Answer\u{2026}** on its card in the Highlights panel or on the library\u{2019}s Highlights page, or in the popover when you click it on the page. Write what you found (or nothing) and press Return.")
            Paragraph("The question gets a check, and it no longer counts as open: the library\u{2019}s **Open questions** filter and its count only include the ones still open. On the Highlights page, choose Question to show only the open or only the answered ones.")
            Paragraph("Click an answer to change it. To open a question again, Control-click it and choose Mark as Unanswered. Answers are kept in Sheaf\u{2019}s library, not in the PDF, and the Markdown exports have them under their question.")
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("**Review** turns your highlights into flashcards, for revising. Choose Go \u{203A} Review Highlights (\u{21E7}\u{2318}R), or Review in the library\u{2019}s left panel.")
            Step(number: 1, title: "Choose the cards") {
                Text("Pick the colors to review (Definitions to start with) and which PDFs: all of them, a collection or one PDF. Then click **Start Review**, or press Return.")
            }
            Step(number: 2, title: "Remember, then check") {
                Text("Each card shows your note on the highlight, or else the PDF and page, and hides what you highlighted. Remember it, then press Space or click the card to see it. Press **1** for Again, and the card comes back a few cards later, or **2** for Got it.")
            }
            Paragraph("Show in PDF opens the PDF at that highlight; the review waits in the library until you come back. At the end, Sheaf lists the cards that needed another look, so you can go through just those again.")
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 18) {
            Subsection("Focus mode", "View \u{203A} Focus Mode (\u{21E7}\u{2318}F) hides the panels and fills the screen with the page. Press Esc or \u{21E7}\u{2318}F to come back.")
            Subsection("Side panels", "Pages and contents are on the left, highlights on the right; the View menu shows or hides them. When the window is too narrow to keep the page a good size beside them, a panel opens over the page instead, and Esc or a click on the page puts it away.")
            Subsection("Bookmarks", "Press \u{2318}D, or click the bookmark in the toolbar, to bookmark the page you\u{2019}re on. Bookmarked pages get a ribbon in the page strip and are listed at the top of the Highlights panel; click one to go there.")
            Subsection("Back", "When you jump somewhere (by following a link, or clicking the contents, a page, a search result or a highlight), a Back button appears at the bottom left of the page. Click it, or press \u{2318}[, to return to where you were. \u{2318}] goes forward again.")
            Subsection("Going to a page", "Go \u{203A} Go to Page (\u{2325}\u{2318}G) takes the page number printed in the PDF, like xii or 245, or a number counted from the first page.")
            Subsection("Reading progress", "The library counts a page as read when you read your way to it, by turning pages or scrolling, or once it has been on screen for ten seconds. A PDF is Finished when every page has been read, so following a link to the references, or jumping to the last page, doesn\u{2019}t finish it.")
            Subsection("Reading aloud", "Edit \u{203A} Speech \u{203A} Start Speaking reads the selected text aloud, or the page if nothing is selected. It uses the voice chosen in System Settings \u{203A} Accessibility \u{203A} Spoken Content.")
            Subsection("Page layout and dark pages", "The View menu and the toolbar set the page layout and size. Sheaf remembers them for the next PDF, and you\u{2019}ll find them in Settings (\u{2318},) too, with Dark Pages in Dark Mode.")
        }
    }

    private var sideBySide: some View {
        VStack(alignment: .leading, spacing: 14) {
            Paragraph("To read two PDFs at once, open one in its own window: choose Open in New Window from the File menu, from the menu when you Control-click a PDF in the library, or from the menu under the PDF\u{2019}s title. In the library\u{2019}s list, Option-double-click or Option-Return does it too.")
            Paragraph("To put the windows side by side, point at the green button at the top left of a window and choose where it goes, or drag it to the edge of the screen. Sheaf fits in half a laptop screen.")
            Paragraph("A PDF is in one window at a time, and Move to Main Window puts it back. Closing its window closes the PDF. The menus act on the window in front, and each window has its own focus mode. Window \u{203A} Merge All Windows keeps PDF windows together as tabs, and they come back the next time you open Sheaf.")
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 18) {
            Subsection("Adding PDFs", "Every PDF you open in Sheaf joins the library and stays where it is on your Mac. File \u{203A} Open (\u{2318}O) takes folders too, adding every PDF inside them. You can also drop PDFs and folders on the library: dropped on a collection they join it, and dropped on Starred they\u{2019}re starred. A PDF in iCloud Drive that isn\u{2019}t on this Mac yet says so in the list, and downloads when you open it.")
            Subsection("Selecting several", "The list works like Finder\u{2019}s: \u{2318}-click or \u{21E7}-click to select several PDFs, or press \u{2318}A for all of them. The File menu, and the menu when you Control-click, act on every PDF selected.")
            Subsection("Quick Look", "Press Space or \u{2318}Y to look at the selected PDFs without opening them.")
            Subsection("Collections", "Click New Collection in the left panel and give it a name. To file PDFs, drag them onto a collection, or choose Add to Collection. Control-click a collection to rename or delete it. Deleting a collection asks first and keeps its PDFs in the library, and \u{2318}Z brings it back.")
            Subsection("Renaming", "Choose Rename\u{2026} from the File menu, from the menu when you Control-click a PDF, or from the menu under a PDF\u{2019}s title.")
            Subsection("Dragging out", "Drag PDFs from the list to Finder, to Mail, or onto a collection.")
            Subsection("Removing", "Press \u{232B}, or choose Remove from Library\u{2026}. Sheaf asks first, and the file stays on your Mac. Changed your mind? \u{2318}Z brings the PDFs back with everything you made in them: highlights, notes, answers, page notes and summary.")
        }
    }

    private var finding: some View {
        VStack(alignment: .leading, spacing: 18) {
            Subsection("In a PDF", "\u{2318}F searches the PDF you\u{2019}re reading, and \u{2318}G and \u{21E7}\u{2318}G step through the matches. Select some text and press \u{2318}E to search for it.")
            Subsection("In the library", "\u{2318}K searches the whole library: the titles of your PDFs, your highlights with their notes and answers, and the words inside the PDFs themselves. A match inside a PDF shows its page, as numbered in the PDF, and the words around it; click it to open the PDF there. Sheaf reads each PDF\u{2019}s text in the background, so one you\u{2019}ve just added may take a moment to show up. Scanned pages are found once you\u{2019}ve opened their PDF and Sheaf has read them.")
            Subsection("In Spotlight", "Your highlights, page notes and summaries are in Spotlight too. Search for words you highlighted or wrote, and the result opens the PDF right there.")
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
