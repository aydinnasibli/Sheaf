import AppKit
import SwiftUI

/// The Sheaf wordmark: four highlighter strokes and the name.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                stroke(.keyIdea, width: 16)
                stroke(.question, width: 12)
                stroke(.definition, width: 16)
                stroke(.evidence, width: 10)
            }
            .accessibilityHidden(true)
            Text("Sheaf")
                .font(Theme.display(18))
                .tracking(-0.3)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sheaf")
    }

    private func stroke(_ kind: HighlightKind, width: CGFloat) -> some View {
        Capsule().fill(kind.vivid).frame(width: width, height: 3.5)
    }
}
