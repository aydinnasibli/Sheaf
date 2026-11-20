import AppKit
import SwiftUI

/// Sheaf's design tokens (direction C, "Highlighter"). Colors adapt to
/// Light and Dark Mode; the only strong color in the interface comes from
/// the four highlighters.
enum Theme {
    // MARK: Surfaces

    static let background = Color(light: 0xFFFFFF, dark: 0x161616)
    static let sidebar = Color(light: 0xFAFAFA, dark: 0x1B1B1B)
    static let raised = Color(light: 0xFFFFFF, dark: 0x1C1C1C)
    static let field = Color(light: 0xF4F4F4, dark: 0x242424)
    /// Behind the pages in the reader.
    static let pageCanvas = Color(light: canvasLight, dark: canvasDark)
    private static let canvasLight: UInt32 = 0xF0F0F0
    private static let canvasDark: UInt32 = 0x0F0F0F

    // MARK: Pages

    /// Paper: under a page's thumbnail or a PDF's cover while it's drawn.
    /// White in Dark Mode too, as the pages themselves are.
    static let paper = Color.white

    /// `pageCanvas` for the page view, which takes a fixed color.
    static func pageCanvas(isDark: Bool) -> NSColor {
        NSColor(hex: isDark ? canvasDark : canvasLight)
    }

    /// The page view's background with Dark Pages on. Its colors are
    /// inverted with the pages', so near-white comes out a dark gray just
    /// lighter than the pages.
    static let darkPagesCanvas = NSColor(hex: 0xFEFEFE)

    /// The edge of a highlight color drawn on the page (a box being dragged,
    /// a search match): the color, a little darker.
    static func edge(of color: NSColor, darkness: CGFloat = 0.35) -> NSColor {
        color.blended(withFraction: darkness, of: .black) ?? color
    }

    /// Selected row in the library list.
    static let selectedRow = Color(light: 0xF2F2F2, dark: 0x262626)
    /// Selected row while the list has keyboard focus.
    static let selectedRowFocused = Color(light: 0xE8E8E8, dark: 0x303030)
    /// Selected item in the library's left panel.
    static let navSelected = Color(light: 0xFFFFFF, dark: 0x2A2A2A)
    /// The picked highlighter in the reader header.
    static let penActive = Color(light: 0xFFFFFF, dark: 0x363636)

    // MARK: Lines

    static let border = Color(light: 0xEBEBEB, dark: 0x2A2A2A)
    static let rowDivider = Color(light: 0xF2F2F2, dark: 0x232323)
    static let control = Color(light: 0xE2E2E2, dark: 0x363636)
    /// The thin edge around a highlighter swatch, so the light colors show on white.
    static let swatchEdge = Color.black.opacity(0.12)

    // MARK: Shadows

    /// Under bars, notices and buttons floating over the page.
    static let floatingShadow = Color.black.opacity(0.12)
    /// Under a side panel shown over the page or the list.
    static let panelShadow = Color.black.opacity(0.16)
    /// Under a page's thumbnail.
    static let thumbnailShadow = Color.black.opacity(0.14)
    /// Under a flashcard.
    static let cardShadow = Color.black.opacity(0.06)

    // MARK: Text

    static let ink = Color(light: 0x111111, dark: 0xF2F2F2)
    static let inkSecondary = Color(light: 0x333333, dark: 0xD6D6D6)
    /// Labels, counts and metadata. Passes 4.5:1 on every surface above.
    static let inkMuted = Color(light: 0x5C5C5C, dark: 0xA3A3A3)
    /// Something that went wrong, like a password that didn't work. Ink,
    /// with a symbol beside it, since the only colors are the highlighters'.
    static let error = ink

    // MARK: Accent

    /// Primary buttons and selection rings: near-black in light, near-white in dark.
    static let accent = ink
    /// Text on `accent`.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x111111)

    // MARK: Interaction

    /// Laid behind or over a control while the pointer is on it.
    static let hoverTint = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.06)
    /// Laid behind or over a control while it's pressed.
    static let pressTint = Color(light: 0x000000, dark: 0xFFFFFF).opacity(0.11)
    /// Dims what's behind a panel shown over the page or the list.
    static let scrim = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: 0x000000, alpha: isDark ? 0.4 : 0.12)
    })
    /// How quickly hover feedback fades in and out.
    static let hoverAnimation = Animation.easeOut(duration: 0.12)
    /// Panels, labels and bars that appear or change size.
    static let motion = Animation.snappy(duration: 0.22)

    // MARK: Type

    /// Space Grotesk, for headings and the wordmark.
    static func display(_ size: CGFloat, weight: NSFont.Weight = .bold) -> Font {
        Font(displayFont(size, weight: weight))
    }

    static func displayFont(_ size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Space Grotesk",
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Section labels like "COLLECTIONS".
    static let sectionLabel = Font.system(size: 11, weight: .bold)

    // MARK: Collections

    /// Colors given to collections, in creation order.
    static let collectionColors: [Color] = [
        Color(light: 0xFFD43B, dark: 0xFFD43B),
        Color(light: 0x74C0FC, dark: 0x74C0FC),
        Color(light: 0x8CE99A, dark: 0x69DB7C),
        Color(light: 0xFF8FAB, dark: 0xFF8FAB),
    ]

    static func collectionColor(_ index: Int) -> Color {
        collectionColors[((index % collectionColors.count) + collectionColors.count) % collectionColors.count]
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// A color that switches between two hex values with the system appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}
