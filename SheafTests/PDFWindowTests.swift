import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// PDFs in their own windows: one window per PDF, moving between the main
/// window and its own, saving when its window closes, coming back at launch,
/// and what the menus act on. The windows themselves aren't opened here;
/// the workspace's requests for them are recorded instead.
@MainActor
struct PDFWindowTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let preferences: UserDefaults

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        preferences = try #require(UserDefaults(suiteName: "SheafPDFWindowTests.\(UUID().uuidString)"))
    }

    private func entry(named name: String) throws -> LibraryEntry {
        let url = try TestFiles.pdf(named: "\(name).pdf", pages: ["\(name) starts here", "\(name) goes on"])
        return try #require(store.add(urls: [url]).first)
    }

    /// A workspace that records the windows it asks to bring forward.
    private func workspace() -> (Workspace, Shown) {
        let workspace = Workspace(library: store, preferences: preferences)
        let shown = Shown()
        workspace.showWindow = { shown.windows.append($0) }
        return (workspace, shown)
    }

    private final class Shown {
        var windows: [ReaderWindow.Kind] = []
    }

    private func finishLoading(_ workspaces: Workspace...) async {
        for document in workspaces.flatMap(\.allDocuments) {
            await document.waitUntilLoaded()
        }
    }

    // MARK: Moving between windows

    @Test func aPDFMovesToItsOwnWindowAndBack() async throws {
        let (workspace, shown) = workspace()
        let paper = try entry(named: "Paper")
        let supplement = try entry(named: "Supplement")
        workspace.open(paper)
        workspace.open(supplement)
        let document = try #require(workspace.selectedDocument)
        await document.waitUntilLoaded()
        let model = try #require(document.model)

        workspace.openInNewWindow(supplement)

        // Out of the main window, which goes back to the library…
        #expect(workspace.documents.map(\.id) == [paper.id])
        #expect(workspace.isShowingLibrary)
        // …and into its own, keeping its reader (page, zoom, search).
        #expect(workspace.windowedDocuments.map(\.id) == [supplement.id])
        #expect(workspace.windowedDocument(id: supplement.id) === document)
        #expect(document.model === model)
        #expect(shown.windows.last == .pdf(supplement.id))
        #expect(preferences.stringArray(forKey: "openDocuments") == [paper.id.uuidString])
        #expect(preferences.stringArray(forKey: "windowedDocuments") == [supplement.id.uuidString])

        // The window appears and finds it there.
        #expect(workspace.ownWindowDidAppear(supplement.id))
        #expect(workspace.windowedDocuments.count == 1)

        workspace.moveToMainWindow(supplement.id)

        #expect(workspace.windowedDocuments.isEmpty)
        #expect(workspace.documents.map(\.id) == [paper.id, supplement.id])
        #expect(workspace.selectedDocument === document)
        #expect(document.model === model)
        #expect(shown.windows.last == .main)
        #expect(preferences.stringArray(forKey: "windowedDocuments") == [])
        // Its window closes now; that doesn't close the PDF.
        workspace.ownWindowDidClose(supplement.id)
        #expect(workspace.selectedDocument === document)
        await finishLoading(workspace)
    }

    @Test func aPDFThatIsntOpenGetsANewWindow() async throws {
        let (workspace, shown) = workspace()
        let paper = try entry(named: "Paper")
        workspace.openPDFsInNewWindows([paper])

        #expect(workspace.documents.isEmpty)
        #expect(workspace.windowedDocuments.map(\.id) == [paper.id])
        #expect(shown.windows == [.pdf(paper.id)])
        // It loads once its window is on screen.
        let document = try #require(workspace.windowedDocument(id: paper.id))
        #expect(!document.hasStartedLoading)
        #expect(workspace.ownWindowDidAppear(paper.id))
        #expect(document.hasStartedLoading)
        await finishLoading(workspace)
    }

    // MARK: One window per PDF

    @Test func openingAPDFInItsOwnWindowAgainBringsThatWindowForward() async throws {
        let (workspace, shown) = workspace()
        let paper = try entry(named: "Paper")
        let record = store.addHighlight(to: paper, pageIndex: 1, kind: .question, text: "goes on", rects: [CGRect(x: 72, y: 700, width: 60, height: 14)])
        workspace.openInNewWindow(paper)
        _ = workspace.ownWindowDidAppear(paper.id)
        let document = try #require(workspace.windowedDocument(id: paper.id))

        // From the library's list, Finder or Spotlight…
        workspace.openPDFs([paper])
        workspace.open(paper, at: record)
        workspace.open(paper, atPage: 1)
        // …and asking for a new window again.
        workspace.openInNewWindow(paper)

        #expect(workspace.documents.isEmpty, "Not in the main window as well")
        #expect(workspace.windowedDocuments.count == 1)
        #expect(workspace.windowedDocument(id: paper.id) === document)
        #expect(shown.windows.allSatisfy { $0 == .pdf(paper.id) })
        #expect(shown.windows.count == 5)
        // Its window scrolls to the highlight and the page.
        #expect(document.pendingHighlightID == record.id)
        #expect(document.pendingPageIndex == 1)
        await finishLoading(workspace)
    }

    // MARK: Closing

    @Test func closingAPDFsWindowClosesItAndSavesFirst() async throws {
        let (workspace, _) = workspace()
        let paper = try entry(named: "Paper")
        let url = URL(filePath: paper.lastKnownPath)
        workspace.openInNewWindow(paper)
        _ = workspace.ownWindowDidAppear(paper.id)
        let document = try #require(workspace.windowedDocument(id: paper.id))
        await document.waitUntilLoaded()
        let model = try #require(document.model)

        model.pdfView.currentSelection = try #require(model.document.findString("Paper starts", withOptions: []).first)
        #expect(model.highlightSelection(as: .keyIdea))
        let id = try #require(model.highlights.first?.id)

        workspace.ownWindowDidClose(paper.id)

        #expect(workspace.windowedDocuments.isEmpty)
        #expect(!workspace.isOpen(paper.id))
        #expect(preferences.stringArray(forKey: "windowedDocuments") == [])
        // The save started on closing, not after the usual pause.
        await SaveTracker.shared.waitForAll()
        let saved = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: saved) == [id])
    }

    @Test func quittingKeepsPDFWindowsForNextTime() async throws {
        let (workspace, _) = workspace()
        let paper = try entry(named: "Paper")
        workspace.openInNewWindow(paper)
        _ = workspace.ownWindowDidAppear(paper.id)

        workspace.isQuitting = true
        workspace.ownWindowDidClose(paper.id)

        #expect(workspace.windowedDocuments.map(\.id) == [paper.id])
        #expect(preferences.stringArray(forKey: "windowedDocuments") == [paper.id.uuidString])
        await finishLoading(workspace)
    }

    @Test func removingAPDFFromTheLibraryClosesItsWindow() async throws {
        let (workspace, _) = workspace()
        let paper = try entry(named: "Paper")
        workspace.openInNewWindow(paper)
        _ = workspace.ownWindowDidAppear(paper.id)
        let document = try #require(workspace.windowedDocument(id: paper.id))
        await document.waitUntilLoaded()

        workspace.remove([paper.id], undoManager: nil)

        #expect(workspace.windowedDocuments.isEmpty)
        // A window macOS reopens later for it has nothing to show, and closes.
        #expect(!workspace.ownWindowDidAppear(paper.id))
    }

    // MARK: Restoring

    @Test func pdfWindowsComeBackAtLaunch() async throws {
        let paper = try entry(named: "Paper")
        let supplement = try entry(named: "Supplement")
        let appendix = try entry(named: "Appendix")
        let (workspace, _) = workspace()
        workspace.open(paper)
        workspace.openInNewWindow(supplement)
        workspace.openInNewWindow(appendix)
        workspace.open(paper)

        let relaunched = Workspace(library: store, preferences: preferences)
        relaunched.restore()

        // Until their windows come back, they're with the main window's PDFs…
        #expect(relaunched.documents.map(\.id) == [paper.id, supplement.id, appendix.id])
        #expect(relaunched.selectedID == paper.id)
        #expect(relaunched.windowedDocuments.isEmpty)
        // …and none of them loads yet.
        #expect(relaunched.documents.map(\.hasStartedLoading) == [true, false, false])

        // macOS reopens the supplement's window, which takes it back. The
        // appendix's window doesn't come back: it stays under "Open now".
        #expect(relaunched.ownWindowDidAppear(supplement.id))
        #expect(relaunched.documents.map(\.id) == [paper.id, appendix.id])
        #expect(relaunched.windowedDocuments.map(\.id) == [supplement.id])
        #expect(relaunched.selectedID == paper.id, "The main window keeps its PDF")
        #expect(relaunched.windowedDocuments[0].hasStartedLoading)
        await finishLoading(workspace, relaunched)
    }

    @Test func aWindowReopenedWithoutItsSavedListStillFindsItsPDF() async throws {
        let paper = try entry(named: "Paper")
        let relaunched = Workspace(library: store, preferences: preferences)
        relaunched.restore()

        #expect(relaunched.ownWindowDidAppear(paper.id))
        #expect(relaunched.windowedDocuments.map(\.id) == [paper.id])
        #expect(!relaunched.ownWindowDidAppear(UUID()), "Not in the library")
        await finishLoading(relaunched)
    }

    // MARK: What the menus act on

    @Test func theMenusActOnTheWindowInFront() async throws {
        let (workspace, _) = workspace()
        let paper = try entry(named: "Paper")
        let supplement = try entry(named: "Supplement")
        workspace.open(paper)
        workspace.openInNewWindow(supplement)
        _ = workspace.ownWindowDidAppear(supplement.id)
        let ownWindow = ReaderWindow(kind: .pdf(supplement.id))

        #expect(workspace.document(in: workspace.mainWindow)?.id == paper.id)
        #expect(workspace.document(in: ownWindow)?.id == supplement.id)
        #expect(workspace.commandTargets(in: ownWindow).map(\.id) == [supplement.id])
        #expect(workspace.commandTargets(in: workspace.mainWindow).map(\.id) == [paper.id])

        // Focus mode is per window.
        ownWindow.isFocusMode = true
        #expect(!workspace.isFocusMode)

        // A question asked from the PDF's own window appears there.
        workspace.frontWindow = .pdf(supplement.id)
        workspace.requestRename(supplement)
        #expect(workspace.alertWindow == .pdf(supplement.id))
        workspace.renameRequest = nil
        workspace.frontWindow = .main
        workspace.requestRename(paper)
        #expect(workspace.alertWindow == .main)

        // With the library on screen, a PDF window still acts on its own PDF only.
        workspace.showLibrary()
        workspace.librarySelection = [paper.id]
        #expect(workspace.commandTargets(in: ownWindow).map(\.id) == [supplement.id])
        workspace.close(supplement.id)
        #expect(workspace.commandTargets(in: ownWindow).isEmpty)
        await finishLoading(workspace)
    }
}
