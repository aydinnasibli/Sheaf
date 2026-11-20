import Foundation
import Testing
@testable import Sheaf

/// The reader's side panels leave the page room to read: they sit beside it
/// only while the page keeps at least `ReaderPanels.minimumPageWidth`.
@MainActor
struct ReaderPanelsTests {
    private let preferences: UserDefaults

    init() throws {
        preferences = try #require(UserDefaults(suiteName: "SheafReaderPanelsTests.\(UUID().uuidString)"))
    }

    @Test func thePageKeepsRoomBesideThePanels() {
        let page = ReaderPanels.minimumPageWidth
        let highlights = ReaderPanels.Panel.highlights.width
        let pages = ReaderPanels.Panel.pages.width
        #expect(ReaderPanels.minimumWidth(for: .highlights, besideHighlights: false) - highlights >= page)
        #expect(ReaderPanels.minimumWidth(for: .pages, besideHighlights: false) - pages >= page)
        #expect(ReaderPanels.minimumWidth(for: .pages, besideHighlights: true) - pages - highlights >= page)
        // A 900 pt window (a laptop's half, or a small display) used to
        // leave the page about 330 pt.
        #expect(ReaderPanels.minimumWidth(for: .pages, besideHighlights: true) > 900)
    }

    @Test func thePagesPanelMakesWayForTheHighlightsPanel() {
        let panels = ReaderPanels(preferences: preferences)
        panels.setWidth(1366)
        #expect(panels.isBeside(.pages) && panels.isBeside(.highlights))

        // Too narrow for both: the Highlights panel stays.
        panels.setWidth(960)
        #expect(panels.isBeside(.highlights))
        #expect(!panels.isShowing(.pages))

        // Hiding it leaves room for the pages panel again…
        panels.toggle(.highlights)
        #expect(panels.isBeside(.pages))
        // …and showing it takes that room back.
        panels.toggle(.highlights)
        #expect(panels.isBeside(.highlights))
        #expect(!panels.isShowing(.pages))

        // Meanwhile the pages panel's button shows it over the page.
        panels.toggle(.pages)
        #expect(panels.isOver(.pages))
    }
}
