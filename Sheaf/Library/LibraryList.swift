import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension LibraryEntry {
    /// For sorting by collection; PDFs without one sort last.
    var collectionName: String { collection?.name ?? "\u{10FFFF}" }
}

/// Column widths, as fractions of the list width (from the mockup).
enum Columns {
    static let title: CGFloat = 0.41
    static let collection: CGFloat = 0.20
    static let highlights: CGFloat = 0.18
    static let read: CGFloat = 0.09
    static let opened: CGFloat = 0.12
}

struct ColumnHeader: View {
    @Binding var sortColumn: LibraryColumn
    @Binding var ascending: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                header("Title", .title, width * Columns.title)
                header("Collection", .collection, width * Columns.collection)
                header("Highlights", .highlights, width * Columns.highlights)
                header("Read", .read, width * Columns.read)
                header("Opened", .opened, width * Columns.opened)
            }
        }
        .frame(height: 34)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func header(_ title: String, _ column: LibraryColumn, _ width: CGFloat) -> some View {
        ColumnHeaderButton(title: title, isSorted: sortColumn == column, ascending: ascending) {
            if sortColumn == column {
                ascending.toggle()
            } else {
                sortColumn = column
                ascending = column == .title || column == .collection
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A sortable column title. The text brightens under the pointer, since a
/// tinted box would sit flush against the column edge.
private struct ColumnHeaderButton: View {
    let title: String
    let isSorted: Bool
    let ascending: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if isSorted {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isSorted || isHovered ? Theme.ink : Theme.inkMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(Theme.hoverAnimation, value: isHovered)
        }
        .buttonStyle(.sheaf(.quiet, in: Rectangle()))
        .onHover { isHovered = $0 }
        .help(isSorted ? "Reverse the order" : "Sort by \(title)")
        .accessibilityLabel("Sort by \(title)")
    }
}

struct LibraryRow: View {
    let entry: LibraryEntry
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    Cover(data: entry.cover)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(entry.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            if entry.isStarred {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.inkMuted)
                                    .accessibilityLabel("Starred")
                            }
                        }
                        Text(entry.pageCount == 1 ? "1 page" : "\(entry.pageCount) pages")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Spacer(minLength: 12)
                }
                .frame(width: width * Columns.title, alignment: .leading)

                Group {
                    if let collection = entry.collection {
                        HStack(spacing: 7) {
                            Swatch(color: Theme.collectionColor(collection.colorIndex), size: 10)
                            Text(collection.name).lineLimit(1)
                        }
                    } else {
                        Text("\u{2014}").foregroundStyle(Theme.inkMuted)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: width * Columns.collection, alignment: .leading)

                HStack(spacing: 8) {
                    let counts = entry.highlightCounts
                    let total = counts.reduce(0, +)
                    HighlightMixBar(counts: counts, width: min(88, width * Columns.highlights - 36))
                    Text(total == 0 ? "\u{2014}" : String(total))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkSecondary)
                }
                .frame(width: width * Columns.highlights, alignment: .leading)

                Text(entry.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(entry.readingStatus == .unread ? Theme.inkMuted : Theme.inkSecondary)
                    .frame(width: width * Columns.read, alignment: .leading)

                Text(entry.lastOpenedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .frame(width: width * Columns.opened, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 58)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Theme.selectedRow : (isHovered ? Theme.selectedRow.opacity(0.5) : .clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowDivider).frame(height: 1).padding(.horizontal, 8)
        }
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .animation(Theme.hoverAnimation, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-click to open")
    }
}

struct Cover: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.white
            }
        }
        .frame(width: 24, height: 30)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.control, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct EmptyLibrary: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.inkMuted)
            Text("Your library is empty")
                .font(Theme.display(22))
                .foregroundStyle(Theme.ink)
            Text("Open a PDF or drag one here. Every PDF you open in Sheaf is added automatically and stays where it is on your Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            PrimaryButton(title: "Open PDF\u{2026}", systemImage: "plus") {
                WindowRouter.shared.showOpenPanel()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
