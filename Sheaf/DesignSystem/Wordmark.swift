import AppKit
import SwiftUI

/// The Sheaf wordmark: the app icon's fan of pages and the name.
struct Wordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            FannedPages()
                .frame(width: 24, height: 22)
                .accessibilityHidden(true)
            Text("Sheaf")
                .font(Theme.display(18))
                .tracking(-0.3)
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sheaf")
    }
}

/// The mark from the app icon, small: four sheets in the highlighter
/// colors fanned out behind a white page, all turning around one point
/// below them (the same angles as Scripts/make-app-icon.swift).
private struct FannedPages: View {
    private static let sheets: [(kind: HighlightKind, degrees: Double)] = [
        (.keyIdea, -22), (.evidence, 22), (.question, -11), (.definition, 11),
    ]
    /// The point the sheets turn around, as a fraction of a sheet: centered,
    /// a little below its bottom edge.
    private static let pivot = UnitPoint(x: 0.5, y: 1.14)

    var body: some View {
        ZStack {
            ForEach(Self.sheets, id: \.kind) { sheet in
                page.fill(sheet.kind.vivid)
                    .frame(width: 10, height: 14)
                    .rotationEffect(.degrees(sheet.degrees), anchor: Self.pivot)
            }
            page.fill(Theme.paper)
                .overlay(page.strokeBorder(Theme.swatchEdge, lineWidth: 1))
                .frame(width: 10, height: 14)
        }
        .offset(y: 2)
    }

    private var page: RoundedRectangle { RoundedRectangle(cornerRadius: 1.8) }
}
