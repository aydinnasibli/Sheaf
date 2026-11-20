import SwiftUI

/// The frame every page of the library shares: Library, Highlights, Notes
/// and Review. Its side margins grow with the page, like CSS's `clamp()`:
/// 20 pt in a window of 680, up to 40 pt on a wide display. On a very wide
/// display the content stops at `maxContentWidth` and sits in the middle,
/// so the list's rows and the cards' text don't stretch out of reach.
enum PageContainer {
    static let topMargin: CGFloat = 26
    static let minimumSideMargin: CGFloat = 20
    static let maximumSideMargin: CGFloat = 40
    /// The widest the content gets, margins aside.
    static let maxContentWidth: CGFloat = 1600

    /// The side margin for a page `width` wide: 3% of it, kept between the
    /// minimum and the maximum.
    static func sideMargin(forWidth width: CGFloat) -> CGFloat {
        min(maximumSideMargin, max(minimumSideMargin, (width * 0.03).rounded()))
    }
}

extension View {
    /// Lays the view out as a page of the library; see `PageContainer`.
    func libraryPage() -> some View {
        modifier(LibraryPageModifier())
    }
}

private struct LibraryPageModifier: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: PageContainer.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, PageContainer.sideMargin(forWidth: width))
            .padding(.top, PageContainer.topMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
    }
}
