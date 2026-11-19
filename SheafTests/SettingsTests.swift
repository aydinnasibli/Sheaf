import AppKit
import Foundation
import PDFKit
import Testing
@testable import Sheaf

@MainActor
struct SettingsTests {
    /// A throwaway preferences domain, so tests never change the app's settings.
    private let preferences: UserDefaults

    init() throws {
        preferences = try #require(UserDefaults(suiteName: "SheafSettingsTests.\(UUID().uuidString)"))
    }

    private func makeReader() -> ReaderModel {
        ReaderModel(document: TestPDF.make(pages: ["One", "Two", "Three"]), entry: nil, store: nil, fileURL: nil, preferences: preferences)
    }

    @Test func withNothingSavedSettingsShowWhatANewPDFUses() {
        let settings = ReadingSettings(preferences: preferences) { [] }
        let reader = makeReader()

        #expect(settings.layout == reader.layout)
        #expect(settings.zoomMode == reader.zoomMode)
        #expect(settings.showsBookSpreads == reader.showsBookSpreads)
        #expect(!settings.darkPages)
    }

    @Test func settingsWriteTheReadersPreferenceKeys() {
        let settings = ReadingSettings(preferences: preferences) { [] }

        settings.layout = .twoPages
        settings.zoomMode = .fitWidth
        settings.showsBookSpreads = true
        settings.darkPages = true

        #expect(preferences.string(forKey: "pageLayout") == "twoPages")
        #expect(preferences.string(forKey: "zoomMode") == "fitWidth")
        #expect(preferences.bool(forKey: "bookSpreads"))
        #expect(preferences.bool(forKey: "darkPages"))

        // The next PDF opens the way Settings says.
        let reader = makeReader()
        #expect(reader.layout == .twoPages)
        #expect(reader.zoomMode == .fitWidth)
        #expect(reader.showsBookSpreads)
    }

    @Test func changingASettingChangesTheOpenPDFs() {
        let reader = makeReader()
        let settings = ReadingSettings(preferences: preferences) { [reader] }

        settings.layout = .twoPageScroll
        settings.zoomMode = .fitPage
        settings.showsBookSpreads = true

        #expect(reader.layout == .twoPageScroll)
        #expect(reader.zoomMode == .fitPage)
        #expect(reader.showsBookSpreads)
    }

    @Test func changesInTheViewMenuShowInSettings() async throws {
        let reader = makeReader()
        let settings = ReadingSettings(preferences: preferences) { [reader] }
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = settings.layout } onChange: { changed = true }

        // What View > Single Page and View > Fit Page do.
        reader.layout = .single
        reader.zoomToFit()

        try await waitUntil { changed }
        #expect(settings.layout == .single)
        #expect(settings.zoomMode == .fitPage)
    }

    @Test func changingTheLayoutKeepsTheZoom() {
        let settings = ReadingSettings(preferences: preferences) { [] }
        // Scrolling pages fill the width until a zoom is picked…
        #expect(settings.zoomMode == .fitWidth)

        settings.layout = .twoPages

        // …and switching to two pages doesn't quietly change that.
        #expect(settings.zoomMode == .fitWidth)
    }
}
