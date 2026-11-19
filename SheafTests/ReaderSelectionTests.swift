import AppKit
import Foundation
import PDFKit
import Testing
@testable import Sheaf

/// Edit > Find > Use Selection for Find, and what Edit > Speech reads.
@MainActor
struct ReaderSelectionTests {
    private func makeReader(pages: [String]) throws -> ReaderModel {
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        return ReaderModel(document: TestPDF.make(pages: pages), entry: nil, store: nil, fileURL: nil, preferences: preferences)
    }

    private func select(_ text: String, in model: ReaderModel) throws {
        model.pdfView.currentSelection = try #require(model.document.findString(text, withOptions: []).first)
    }

    /// A pasteboard of the test's own, so the Mac's shared Find text is left alone.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("SheafTests.\(UUID().uuidString)"))
    }

    @Test func useSelectionForFindSearchesForTheSelectedText() throws {
        let model = try makeReader(pages: ["The quick brown fox", "Another fox"])
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        try select("quick brown", in: model)

        #expect(model.useSelectionForFind(pasteboard: pasteboard))

        #expect(model.searchQuery == "quick brown")
        #expect(model.isSearchBarVisible)
        #expect(model.searchFocusRequest == 1)
        #expect(pasteboard.string(forType: .string) == "quick brown")
    }

    @Test func useSelectionForFindDoesNothingWithoutASelection() throws {
        let model = try makeReader(pages: ["The quick brown fox"])
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        model.searchQuery = "fox"

        #expect(!model.useSelectionForFind(pasteboard: pasteboard))

        #expect(model.searchQuery == "fox")
        #expect(model.searchFocusRequest == 0)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func speechReadsTheSelectionOrElseThePage() throws {
        let model = try makeReader(pages: ["The quick brown fox", "Second page"])
        #expect(model.textToSpeak == "The quick brown fox")

        try select("brown fox", in: model)
        #expect(model.textToSpeak == "brown fox")
    }

    @Test func aPageWithoutTextHasNothingToSpeak() throws {
        let model = try makeReader(pages: [""])
        #expect(model.textToSpeak == nil)
    }
}
