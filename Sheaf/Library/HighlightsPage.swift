import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Every highlight from every PDF, newest first, filterable by color and
/// searchable from the header. Clicking one opens the PDF at that spot.
struct HighlightsPage: View {
    let title: String
    let records: [HighlightRecord]
    let searchText: String
    /// The colors shown; empty means all. Shared with the sidebar's color rows.
    @Binding var kinds: Set<HighlightKind>
    let onOpen: (HighlightRecord) -> Void

    private var shown: [HighlightRecord] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return records.filter { record in
            (kinds.isEmpty || kinds.contains(record.kind))
                && (query.isEmpty
                    || record.text.localizedStandardContains(query)
                    || record.note.localizedStandardContains(query)
                    || (record.entry?.title.localizedStandardContains(query) ?? false))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(Theme.display(32))
                    .tracking(-0.9)
                    .foregroundStyle(Theme.ink)
                Text(shown.count == 1 ? "1 highlight" : "\(shown.count) highlights")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkMuted)
            }

            FlowLayout(spacing: 6) {
                FilterChip(title: "All colors", isSelected: kinds.isEmpty) { kinds = [] }
                ForEach(HighlightKind.allCases) { kind in
                    FilterChip(title: kind.name, dot: kind.vivid, isSelected: kinds.contains(kind)) {
                        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
                    }
                }
            }

            if shown.isEmpty {
                if records.isEmpty {
                    EmptyMessage(
                        systemImage: "highlighter",
                        title: "Nothing here yet",
                        message: "Open a PDF, select some text and press 1\u{2013}4. Every highlight you make shows up here."
                    )
                } else if kinds.isEmpty {
                    EmptyMessage(systemImage: "magnifyingglass", title: "No matches", message: "Try another search.")
                } else {
                    EmptyMessage(
                        systemImage: "highlighter",
                        title: "No matches",
                        message: "No highlights of \(kinds.count == 1 ? "this color" : "these colors") match.",
                        actionTitle: "Show All Colors"
                    ) { kinds = [] }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(shown) { record in
                            Button { onOpen(record) } label: { card(record) }
                                .buttonStyle(.sheaf(.overlay, cornerRadius: 12))
                                .accessibilityLabel(Self.spokenLabel(for: record))
                                .help("Open \u{201C}\(record.entry?.title ?? "PDF")\u{201D} at page \(record.pageIndex + 1)")
                                .contextMenu {
                                    Button("Open in PDF") { onOpen(record) }
                                    Button("Copy Text") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(record.text, forType: .string)
                                    }
                                }
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What VoiceOver reads for a highlight card.
    static func spokenLabel(for record: HighlightRecord) -> String {
        var label = "\(record.kind.name): \(record.text). \(record.entry?.title ?? "PDF"), page \(record.pageIndex + 1)"
        if !record.note.isEmpty { label += ". Note: \(record.note)" }
        return label
    }

    private func card(_ record: HighlightRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(record.kind.name.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(record.kind.chipText)
                Spacer()
                Text(record.createdAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSecondary)
            }
            Text(record.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading)
            if !record.note.isEmpty {
                Text(record.note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.leading)
            }
            Text("\(record.entry?.title ?? "PDF") \u{00B7} p. \(record.pageIndex + 1)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(record.kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
    }
}
