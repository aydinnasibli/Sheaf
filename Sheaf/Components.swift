import SwiftUI

// Small building blocks shared by the library and the reader, drawn to
// match the direction C mockups.

extension ToolbarContent {
    /// Removes the glass capsule macOS 26 draws behind toolbar items, so the
    /// header matches Sheaf's own design. No effect on earlier macOS versions.
    @ToolbarContentBuilder
    func plainBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension View {
    /// The Sheaf header: background color and no title text in the toolbar.
    /// The window title is still set, so tabs and the Window menu show it.
    func sheafHeader() -> some View {
        toolbar(removing: .title)
            .toolbarBackground(Theme.background, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}

/// A 1-point line in the border color.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// A bordered group of controls, like the page and zoom controls.
struct Pill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: 32)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.control, lineWidth: 1))
    }
}

/// An icon-only button inside a `Pill`.
struct PillIconButton: View {
    let label: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? Theme.ink : Theme.inkMuted)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A square bordered icon button, like Back and Search.
struct SquareIconButton: View {
    let label: String
    let systemImage: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .foregroundStyle(isOn ? Theme.onAccent : Theme.ink)
                .background(isOn ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? .clear : Theme.control, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The black (white in Dark Mode) main button.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .bold))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .foregroundStyle(Theme.onAccent)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A rounded filter chip. Selected chips are filled with the accent.
struct FilterChip: View {
    let title: String
    var dot: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot {
                    Circle().fill(dot).frame(width: 9, height: 9).accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .foregroundStyle(isSelected ? Theme.onAccent : Theme.inkSecondary)
            .background(isSelected ? Theme.accent : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.control, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small rounded square in a highlighter or collection color.
struct Swatch: View {
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "COLLECTIONS"-style section label.
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(Theme.sectionLabel)
            .tracking(0.7)
            .foregroundStyle(Theme.inkMuted)
    }
}

/// Lays children out in rows, wrapping to a new row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > maxWidth, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// The stacked bar showing how many highlights of each kind a PDF has.
struct HighlightMixBar: View {
    /// Counts in `HighlightKind.allCases` order.
    let counts: [Int]
    var width: CGFloat = 88

    var body: some View {
        let total = counts.reduce(0, +)
        HStack(spacing: 0) {
            ForEach(Array(HighlightKind.allCases.enumerated()), id: \.element) { index, kind in
                if total > 0, counts[index] > 0 {
                    Rectangle()
                        .fill(kind.swatch)
                        .frame(width: width * CGFloat(counts[index]) / CGFloat(total))
                }
            }
        }
        .frame(width: width, height: 8, alignment: .leading)
        .background(Theme.field)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}
