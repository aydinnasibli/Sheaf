import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

@MainActor
struct WorkspaceTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let preferences: UserDefaults

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        preferences = try #require(UserDefaults(suiteName: "SheafWorkspaceTests.\(UUID().uuidString)"))
    }

    private func entry(named name: String) throws -> LibraryEntry {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SheafWorkspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).pdf")
        #expect(TestPDF.make(pages: [name]).write(to: url))
        return try #require(store.add(urls: [url]).first)
    }

    @Test func openingShowsThePDFAndBackShowsTheLibrary() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Paper")

        workspace.open(paper)
        #expect(workspace.selectedDocument?.id == paper.id)
        #expect(workspace.selectedDocument?.model != nil)

        workspace.showLibrary()
        #expect(workspace.isShowingLibrary)
        #expect(workspace.documents.count == 1)
    }

    @Test func openingTheSamePDFTwiceKeepsOneCopy() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Paper")
        workspace.open(paper)
        workspace.showLibrary()
        workspace.open(paper)
        #expect(workspace.documents.count == 1)
    }

    @Test func controlTabCyclesThroughLibraryAndOpenPDFs() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let first = try entry(named: "First")
        let second = try entry(named: "Second")
        workspace.open(first)
        workspace.open(second)

        workspace.selectNext()
        #expect(workspace.isShowingLibrary)
        workspace.selectNext()
        #expect(workspace.selectedID == first.id)
        workspace.selectPrevious()
        #expect(workspace.isShowingLibrary)
    }

    @Test func closingThePDFOnScreenReturnsToTheLibrary() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Paper")
        workspace.open(paper)
        workspace.close(paper.id)
        #expect(workspace.documents.isEmpty)
        #expect(workspace.isShowingLibrary)
    }

    @Test func focusModeLastsWhileSwitchingPDFsAndEndsInTheLibrary() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let first = try entry(named: "First")
        let second = try entry(named: "Second")
        workspace.open(first)
        workspace.open(second)
        workspace.isFocusMode = true

        workspace.select(first.id)
        #expect(workspace.isFocusMode)

        workspace.showLibrary()
        #expect(!workspace.isFocusMode)

        workspace.open(first)
        workspace.isFocusMode = true
        workspace.close(first.id)
        #expect(!workspace.isFocusMode)
    }

    @Test func openPDFsAreReopenedNextLaunch() throws {
        let first = try entry(named: "First")
        let second = try entry(named: "Second")
        let workspace = Workspace(library: store, preferences: preferences)
        workspace.open(first)
        workspace.open(second)

        let relaunched = Workspace(library: store, preferences: preferences)
        relaunched.restore()

        #expect(relaunched.documents.map(\.id) == [first.id, second.id])
        #expect(relaunched.selectedID == second.id)
    }
}
