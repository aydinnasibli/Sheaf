import Foundation
import Observation

/// The reader's two side panels: pages and contents on the left, highlights
/// (or search results) on the right.
///
/// Each sits beside the page when the window is wide enough to leave the
/// page at least `minimumPageWidth`, and whether it shows there is
/// remembered between launches. The Highlights panel comes first: with it
/// beside the page, the pages panel needs a wider window. In a narrower
/// window (half of a laptop screen, say) a panel's button still works: the
/// panel opens over the page instead, until Esc, the button again or a
/// click on the page puts it away. Only one panel is over the page at a time.
@Observable
final class ReaderPanels {
    enum Panel: CaseIterable {
        case pages, highlights

        /// The panel's widest, with its divider: the pages panel showing the
        /// contents (PageStrip), the Highlights panel (ReaderLayout).
        var width: CGFloat { self == .pages ? 261 : 313 }

        /// Where "show beside the page" is remembered.
        var preferenceKey: String { self == .pages ? "showsThumbnails" : "showsHighlightsPanel" }
    }

    /// The page keeps at least this much room beside the panels, so a
    /// line of a paper stays readable at a sensible size.
    static let minimumPageWidth: CGFloat = 480

    /// The narrowest reader a panel fits beside the page in: 800 for the
    /// Highlights panel; 760 for the pages panel alone, 1060 beside the
    /// Highlights panel.
    static func minimumWidth(for panel: Panel, besideHighlights: Bool) -> CGFloat {
        let panels = panel == .pages && besideHighlights ? Panel.pages.width + Panel.highlights.width : panel.width
        return ((minimumPageWidth + panels) / 20).rounded(.up) * 20
    }

    /// The panel shown over the page, if any.
    private(set) var overlay: Panel?
    private var pinned: [Panel: Bool]
    /// Which panels fit beside the page at the reader's current width.
    /// Changes only when a width threshold is crossed, so resizing the
    /// window doesn't rebuild the menus on every step.
    private var fitting: Set<Panel> = Set(Panel.allCases)
    @ObservationIgnored private var width: CGFloat?

    @ObservationIgnored private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        pinned = Dictionary(uniqueKeysWithValues: Panel.allCases.map { panel in
            (panel, preferences.object(forKey: panel.preferenceKey) as? Bool ?? true)
        })
    }

    /// Whether the panel fits beside the page.
    func fits(_ panel: Panel) -> Bool { fitting.contains(panel) }

    /// Shown beside the page.
    func isBeside(_ panel: Panel) -> Bool { fits(panel) && pinned[panel] == true }

    /// Shown over the page.
    func isOver(_ panel: Panel) -> Bool { !fits(panel) && overlay == panel }

    /// Shown either way, for the View menu's check marks.
    func isShowing(_ panel: Panel) -> Bool { isBeside(panel) || isOver(panel) }

    /// The panel's button and menu item: shows or hides it beside the page
    /// if it fits there, and over the page if it doesn't.
    func toggle(_ panel: Panel) {
        if fits(panel) {
            let shows = !(pinned[panel] ?? true)
            pinned[panel] = shows
            preferences.set(shows, forKey: panel.preferenceKey)
            // Showing or hiding the Highlights panel changes the room left
            // for the pages panel.
            updateFitting()
        } else {
            overlay = overlay == panel ? nil : panel
        }
    }

    /// Puts away the panel over the page. Returns false if there wasn't one.
    @discardableResult
    func closeOverlay() -> Bool {
        guard overlay != nil else { return false }
        overlay = nil
        return true
    }

    /// Called by the reader as the window resizes.
    func setWidth(_ width: CGFloat) {
        self.width = width
        updateFitting()
    }

    private func updateFitting() {
        guard let width else { return }
        let highlightsFit = width >= Self.minimumWidth(for: .highlights, besideHighlights: false)
        let besideHighlights = highlightsFit && pinned[.highlights] == true
        var nowFitting: Set<Panel> = highlightsFit ? [.highlights] : []
        if width >= Self.minimumWidth(for: .pages, besideHighlights: besideHighlights) {
            nowFitting.insert(.pages)
        }
        guard nowFitting != fitting else { return }
        fitting = nowFitting
        if let overlay, fits(overlay) {
            // There's room now: the panel that was over the page moves
            // beside it and stays.
            pinned[overlay] = true
            preferences.set(true, forKey: overlay.preferenceKey)
            self.overlay = nil
        }
    }
}
