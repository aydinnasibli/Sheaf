import Observation
import SwiftData
import SwiftUI

/// What the library's search of PDF text depends on: when any of it changes,
/// the search runs again.
struct TextSearchKey: Hashable {
    let query: String
    let scope: LibraryScope
    let filter: LibraryFilter
    /// Newly indexed text, while searching (see `TextIndexer.generation`).
    let generation: Int

    init(query: String, scope: LibraryScope, filter: LibraryFilter) {
        self.query = query
        self.scope = scope
        self.filter = filter
        // Only watched while searching, so indexing doesn't redraw the library otherwise.
        self.generation = query.isEmpty ? 0 : TextIndexer.shared.generation
    }
}

/// Searches the text of the PDFs shown in the library, after a pause in typing.
@Observable
final class LibraryTextSearch {
    /// The search the matches are for.
    private(set) var query = ""
    private(set) var matches: [TextIndex.Match] = []

    /// The matches, if they're for this search; older ones aren't shown.
    func matches(for query: String) -> [TextIndex.Match] {
        query == self.query ? matches : []
    }

    /// Whether this search hasn't finished yet.
    func isSearching(_ query: String) -> Bool {
        !query.isEmpty && query != self.query
    }

    func run(_ query: String, in entries: [LibraryEntry]) async {
        guard !query.isEmpty, !entries.isEmpty else {
            self.query = query
            matches = []
            return
        }
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        let found = await TextIndexer.shared.search(query, in: entries)
        guard !Task.isCancelled else { return }
        self.query = query
        matches = found
    }
}

/// PDFs whose text contains the search, under the library's list. Each shows
/// the first few pages where the text appears, with the words around it;
/// clicking one opens the PDF at that page.
struct TextMatchesSection: View {
    let matches: [TextIndex.Match]
    let entries: [LibraryEntry]
    let query: String
    let onOpen: (LibraryEntry, Int) -> Void

    /// The most the list above should take while text matches are shown:
    /// about its rows' height, so a short list doesn't leave a gap. (Rows are
    /// 58 points; the list scrolls if this is short.)
    static func listHeight(rows: Int) -> CGFloat {
        34 + CGFloat(rows) * 58 + 8
    }

    var body: some View {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shown = matches.compactMap { match in byID[match.entryID].map { (match, $0) } }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(title: "Found in the text")
                Text(shown.count == 1 ? "1 PDF" : "\(shown.count) PDFs")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Hairline() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.0.id) { match, entry in
                        TextMatchRow(match: match, entry: entry, query: query, onOpen: onOpen)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

/// One PDF in the text matches: its title, then "p. 12 · …snippet…" for
/// each page shown.
private struct TextMatchRow: View {
    let match: TextIndex.Match
    let entry: LibraryEntry
    let query: String
    let onOpen: (LibraryEntry, Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Cover(data: entry.cover)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .padding(.bottom, 2)
                ForEach(match.pages) { page in
                    Button { onOpen(entry, page.index) } label: {
                        Text(TextMatchesSection.line(for: page, in: entry, query: query))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.sheaf(cornerRadius: 6))
                    .padding(.horizontal, -8)
                    .help("Open \u{201C}\(entry.title)\u{201D} at page \(TextMatchesSection.pageLabel(of: page, in: entry))")
                    .accessibilityLabel("Page \(TextMatchesSection.pageLabel(of: page, in: entry)): \(page.snippet)")
                    .accessibilityHint("Opens \(entry.title) at this page")
                }
                if match.pageCount > match.pages.count {
                    let more = match.pageCount - match.pages.count
                    Text(more == 1 ? "and 1 more page" : "and \(more) more pages")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkMuted)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1)
        }
    }
}

extension TextMatchesSection {
    /// The page as printed in the PDF ("xii", "245"), else its number. The
    /// index has the labels of PDFs never opened; the library remembers
    /// them for PDFs whose labels were lost when highlights were saved.
    static func pageLabel(of page: TextIndex.Match.Page, in entry: LibraryEntry) -> String {
        page.label ?? entry.label(ofPage: page.index)
    }

    /// "p. 12 · …snippet…", with the searched words in bold.
    static func line(for page: TextIndex.Match.Page, in entry: LibraryEntry, query: String) -> AttributedString {
        var number = AttributedString("p. \(pageLabel(of: page, in: entry))")
        number.font = .system(size: 12.5, weight: .semibold).monospacedDigit()
        number.foregroundColor = Theme.ink
        var dot = AttributedString(" \u{00B7} ")
        dot.foregroundColor = Theme.inkMuted
        var snippet = AttributedString(page.snippet)
        if let range = snippet.range(of: TextIndex.normalize(query), options: TextIndex.searchOptions) {
            snippet[range].font = .system(size: 12.5, weight: .semibold)
            snippet[range].foregroundColor = Theme.ink
        }
        return number + dot + snippet
    }
}
