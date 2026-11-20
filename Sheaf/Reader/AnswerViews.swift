import SwiftUI

/// An answered question's answer, with a check: on highlight cards in the
/// reader and the library, and in the highlight popover.
struct AnswerLine: View {
    let answer: String
    /// The check's color: the card's text color for its highlight.
    var tint: Color = Theme.ink
    var font: Font = .system(size: 12.5)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(answer.isEmpty ? "Answered" : answer)
                .foregroundStyle(answer.isEmpty ? Theme.inkMuted : Theme.ink)
                .multilineTextAlignment(.leading)
                // Wraps rather than being cut short, even in the popover.
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(answer.isEmpty ? "Answered" : "Answer: \(answer)")
    }
}

/// A note or answer typed right on a card: Return saves, Esc cancels.
struct CardTextField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var hint = "Return to save \u{00B7} Esc to cancel"
    var background: Color = Theme.field
    var accessibilityLabel = "Note"
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
                .lineLimit(1...6)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .focused(isFocused)
                .onSubmit(save)
                .onExitCommand(perform: cancel)
                .accessibilityLabel(accessibilityLabel)
            Text(hint)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.inkMuted)
        }
    }
}

extension CardTextField {
    /// The hint under an answer being typed.
    static let answerHint = "Return to mark it answered \u{00B7} Esc to cancel"
}
