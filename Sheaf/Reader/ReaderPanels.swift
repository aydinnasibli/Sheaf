import Foundation
import Observation

/// The reader's two side panels: pages and contents on the left, highlights
/// (or search results) on the right.
///
/// Each sits beside the page when the window is wide enough, and whether it
/// shows there is remembered between launches. In a narrower window (half
/// of a laptop screen, say) its button still works: the panel opens over
/// the page instead, until Esc, the button again or a click on the page
/// puts it away. Only one panel is over the page at a time.
@Observable
final class ReaderPanels {
    enum Panel: CaseIterable {
        case pages, highlights

        /// The narrowest reader the panel fits beside the page in.
        var minimumWidth: CGFloat { self == .pages ? 900 : 760 }

        /// Where "show beside the page" is remembered.
        var preferenceKey: String { self == .pages ? "showsThumbnails" : "showsHighlightsPanel" }
    }

    /// The panel shown over the page, if any.
    private(set) var overlay: Panel?
    private var pinned: [Panel: Bool]
    /// Which panels fit beside the page at the reader's current width.
    /// Changes only when a width threshold is crossed, so resizing the
    /// window doesn't rebuild the menus on every step.
    private var fitting: Set<Panel> = Set(Panel.allCases)

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
        let nowFitting = Set(Panel.allCases.filter { width >= $0.minimumWidth })
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
