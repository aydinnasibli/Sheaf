import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RecentHighlightsPanel: View {
    let records: [HighlightRecord]
    let onSelect: (HighlightRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent highlights")
                .font(Theme.display(18))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if records.isEmpty {
                        guide
                    } else {
                        ForEach(records) { record in
                            Button { onSelect(record) } label: { card(record) }
                                .buttonStyle(.sheaf(.overlay, cornerRadius: 12))
                                .accessibilityLabel(HighlightsPage.spokenLabel(for: record))
                                .help("Open at page \(record.displayPage)")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 22)
        .background(Theme.background)
    }

    private func card(_ record: HighlightRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.kind.name.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(record.kind.chipText)
            Text(record.text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
            Text("\(record.entry?.title ?? "PDF") \u{00B7} p. \(record.displayPage)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(record.kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlights you make in any PDF show up here. Each color means something:")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(HighlightKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(kind.name.uppercased())  \u{00B7}  KEY \(kind.rawValue)")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(kind.chipText)
                    Text(kind.purpose)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(kind.chipBackground, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
