import SwiftUI

// MARK: - Button feedback

/// Hover and press feedback for Sheaf's own buttons, with the pointing-hand
/// cursor. Every custom button uses it, so all of them respond the same way.
struct SheafButtonStyle: ButtonStyle {
    enum Feedback {
        /// A tint behind the label, for buttons on a plain background.
        /// Selected buttons with their own fill hide it.
        case fill
        /// A tint over the label, for colored cards and chips.
        case overlay
        /// For buttons filled with the accent color.
        case primary
        /// No tint, only the cursor and a dim while pressed; for text and
        /// buttons inside a card that shows its own hover.
        case quiet
    }

    var feedback: Feedback = .fill
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 8))

    func makeBody(configuration: Configuration) -> some View {
        SheafButtonBody(configuration: configuration, feedback: feedback, shape: shape)
    }
}

extension ButtonStyle where Self == SheafButtonStyle {
    static func sheaf(_ feedback: SheafButtonStyle.Feedback = .fill, cornerRadius: CGFloat = 8) -> SheafButtonStyle {
        SheafButtonStyle(feedback: feedback, shape: AnyShape(RoundedRectangle(cornerRadius: cornerRadius)))
    }

    static func sheaf(_ feedback: SheafButtonStyle.Feedback = .fill, in shape: some Shape) -> SheafButtonStyle {
        SheafButtonStyle(feedback: feedback, shape: AnyShape(shape))
    }
}

private struct SheafButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let feedback: SheafButtonStyle.Feedback
    let shape: AnyShape

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var tint: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return feedback == .primary ? Theme.onAccent.opacity(0.22) : Theme.pressTint }
        if isHovered { return feedback == .primary ? Theme.onAccent.opacity(0.12) : Theme.hoverTint }
        return .clear
    }

    var body: some View {
        configuration.label
            .background {
                if feedback == .fill { shape.fill(tint) }
            }
            .overlay {
                if feedback == .overlay || feedback == .primary { shape.fill(tint).allowsHitTesting(false) }
            }
            .opacity(feedback == .quiet && configuration.isPressed ? 0.6 : 1)
            .animation(Theme.hoverAnimation, value: isHovered)
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .pointerStyle(isEnabled ? .link : nil)
    }
}

// MARK: - Shapes and lines

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
        }
        .buttonStyle(.sheaf(cornerRadius: 7))
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
                .animation(Theme.hoverAnimation, value: isOn)
        }
        .buttonStyle(.sheaf(isOn ? .primary : .fill))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The black (white in Dark Mode) main button.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

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
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(.sheaf(.primary, cornerRadius: 10))
        .accessibilityLabel(title)
    }
}

/// A bordered button for secondary actions, like Export.
struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    var fillsWidth = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.control, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.sheaf(cornerRadius: 10))
        .accessibilityLabel(title)
    }
}

/// A centered icon, title and explanation for an empty list, with an
/// optional way out.
struct EmptyMessage: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.inkMuted)
                .padding(.bottom, 2)
            Text(title)
                .font(Theme.display(20))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle, let action {
                SecondaryButton(title: actionTitle, action: action)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .animation(Theme.hoverAnimation, value: isSelected)
        }
        .buttonStyle(.sheaf(isSelected ? .primary : .fill, in: Capsule()))
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
