import AppKit
import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import Sheaf

/// The commands on PDFs in the library: removing (and Undo), renaming,
/// starring, collections, and what the menu bar acts on.
@MainActor
struct PDFActionsTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let preferences: UserDefaults
    private let index = FakeHighlightIndex()

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        store.searchIndex = index
        preferences = try #require(UserDefaults(suiteName: "SheafPDFActionsTests.\(UUID().uuidString)"))
    }

    private func entry(named name: String, pages: Int = 3) throws -> LibraryEntry {
        let url = try TestFiles.pdf(named: "\(name).pdf", pages: (1...pages).map { "\(name) page \($0)" })
        return try #require(store.add(urls: [url]).first)
    }

    private func allEntries() throws -> [LibraryEntry] {
        try container.mainContext.fetch(FetchDescriptor<LibraryEntry>())
    }

    @discardableResult
    private func highlight(_ entry: LibraryEntry, _ text: String, kind: HighlightKind = .keyIdea, note: String = "") -> HighlightRecord {
        let record = store.addHighlight(to: entry, pageIndex: 1, kind: kind, text: text, rects: [CGRect(x: 72, y: 700, width: 120, height: 14)])
        if !note.isEmpty { store.setNote(note, for: record) }
        return record
    }

    private func undoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    // MARK: Removing

    @Test func removingSeveralPDFsAndUndoingBringsEverythingBack() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let research = store.createCollection(named: "Research")
        let paper = try entry(named: "Paper", pages: 5)
        let notes = try entry(named: "Notes")
        let question = highlight(paper, "Why does it converge?", kind: .question, note: "Ask in the seminar")
        let evidence = highlight(paper, "Table 2", kind: .evidence)
        let definition = highlight(notes, "Entropy", kind: .definition)
        paper.bookmarkedPages = [0, 3]
        paper.recordPage(3)
        paper.recordPage(1)
        store.setStarred(true, for: [paper])
        store.move([paper], to: research)
        workspace.librarySelection = [paper.id, notes.id]

        // What Undo has to bring back, copied before the entries go away.
        let paperID = paper.id, notesID = notes.id
        let expected = (
            title: paper.title, path: paper.lastKnownPath, bookmark: paper.bookmark, cover: paper.cover,
            addedAt: paper.addedAt, lastOpenedAt: paper.lastOpenedAt, pageCount: paper.pageCount
        )
        let highlightIDs = Set([question.id, evidence.id, definition.id])
        let questionCreatedAt = question.createdAt

        let undoManager = undoManager()
        undoManager.beginUndoGrouping()
        workspace.remove([paperID, notesID], undoManager: undoManager)
        undoManager.endUndoGrouping()

        #expect(try allEntries().isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<HighlightRecord>()).isEmpty)
        #expect(workspace.librarySelection.isEmpty)
        #expect(index.changes.last == .removedPDFs([paperID, notesID]))
        #expect(undoManager.undoActionName == "Remove from Library")
        #expect(research.items.isEmpty)

        undoManager.undo()

        let restored = try #require(store.entry(id: paperID))
        #expect(store.entry(id: notesID) != nil)
        #expect(restored.title == expected.title)
        #expect(restored.lastKnownPath == expected.path)
        #expect(restored.bookmark == expected.bookmark)
        #expect(restored.cover == expected.cover)
        #expect(restored.pageCount == expected.pageCount)
        #expect(restored.addedAt == expected.addedAt)
        #expect(restored.lastOpenedAt == expected.lastOpenedAt)
        #expect(restored.lastPageIndex == 1)
        #expect(restored.readPages == [1, 3])
        #expect(restored.isStarred)
        #expect(restored.bookmarkedPages == [0, 3])
        #expect(restored.collection?.id == research.id)
        #expect(Set(try container.mainContext.fetch(FetchDescriptor<HighlightRecord>()).map(\.id)) == highlightIDs)
        let restoredQuestion = try #require(restored.highlights.first { $0.id == question.id })
        #expect(restoredQuestion.note == "Ask in the seminar")
        #expect(restoredQuestion.kind == .question)
        #expect(restoredQuestion.text == "Why does it converge?")
        #expect(restoredQuestion.createdAt == questionCreatedAt)
        #expect(restoredQuestion.rects == [CGRect(x: 72, y: 700, width: 120, height: 14)])
        #expect(store.entry(id: notesID)?.highlights.map(\.id) == [definition.id])
        // Back in Spotlight, and selected in the list again.
        guard case .indexed(let indexed) = index.changes.last else {
            Issue.record("Undo didn't put the highlights back in Spotlight")
            return
        }
        #expect(Set(indexed.map(\.id)) == highlightIDs)
        #expect(workspace.librarySelection == [paperID, notesID])
        // The file can still be opened.
        #expect(store.resolveFile(for: restored) != nil)

        // Redo removes them again.
        undoManager.redo()
        #expect(try allEntries().isEmpty)
    }

    /// Every stored field of a PDF in the library and what it owns, to
    /// compare before removing it and after Undo.
    private struct Everything: Equatable {
        struct Highlight: Equatable {
            let id: UUID, pageIndex: Int, kindRaw: Int, text: String, note: String, createdAt: Date
            let rectValues: [Double], pageLabel: String, isAnswered: Bool, answer: String
        }

        struct Note: Equatable {
            let id: UUID, pageIndex: Int, pageLabel: String, text: String, createdAt: Date, modifiedAt: Date
        }

        let id: UUID, title: String, lastKnownPath: String, bookmark: Data?, pageCount: Int
        let lastPageIndex: Int, furthestPageIndex: Int, readPages: [Int], addedAt: Date, lastOpenedAt: Date
        let isStarred: Bool, bookmarkedPages: [Int], needsFileSave: Bool, removedHighlightIDs: [UUID]
        let summary: String, pageLabels: [String], cover: Data?, collectionID: UUID?
        let highlights: [Highlight]
        let pageNotes: [Note]

        init(_ entry: LibraryEntry) {
            id = entry.id
            title = entry.title
            lastKnownPath = entry.lastKnownPath
            bookmark = entry.bookmark
            pageCount = entry.pageCount
            lastPageIndex = entry.lastPageIndex
            furthestPageIndex = entry.furthestPageIndex
            readPages = entry.readPages
            addedAt = entry.addedAt
            lastOpenedAt = entry.lastOpenedAt
            isStarred = entry.isStarred
            bookmarkedPages = entry.bookmarkedPages
            needsFileSave = entry.needsFileSave
            removedHighlightIDs = entry.removedHighlightIDs
            summary = entry.summary
            pageLabels = entry.pageLabels
            cover = entry.cover
            collectionID = entry.collection?.id
            highlights = entry.highlights.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                Highlight(
                    id: $0.id, pageIndex: $0.pageIndex, kindRaw: $0.kindRaw, text: $0.text, note: $0.note,
                    createdAt: $0.createdAt, rectValues: $0.rectValues, pageLabel: $0.pageLabel,
                    isAnswered: $0.isAnswered, answer: $0.answer
                )
            }
            pageNotes = entry.pageNotes.sorted { $0.pageIndex < $1.pageIndex }.map {
                Note(id: $0.id, pageIndex: $0.pageIndex, pageLabel: $0.pageLabel, text: $0.text, createdAt: $0.createdAt, modifiedAt: $0.modifiedAt)
            }
        }
    }

    @Test func undoBringsBackEverythingOnlySheafKeeps() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let thesis = store.createCollection(named: "Thesis")
        let paper = try entry(named: "Paper", pages: 4)
        let question = highlight(paper, "Why does it converge?", kind: .question, note: "Ask in the seminar")
        question.pageLabel = "xi"
        store.setAnswer("Because of the step size", isAnswered: true, for: question)
        let evidence = highlight(paper, "Table 2", kind: .evidence)
        evidence.pageLabel = "xi"
        store.addPageNote(
            to: paper, pageIndex: 2, pageLabel: "xii", text: "The diagram on the left",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), modifiedAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
        store.addPageNote(to: paper, pageIndex: 3, text: "Compare with chapter 2")
        store.setSummary("Convergence of gradient descent, for chapter 3", for: paper)
        paper.pageLabels = ["ix", "x", "xi", "xii"]
        paper.recordRead([0, 2])
        paper.recordPosition(2)
        paper.bookmarkedPages = [1]
        paper.removedHighlightIDs = [UUID()]
        store.setStarred(true, for: [paper])
        store.move([paper], to: thesis)
        store.save()
        let before = Everything(paper)
        #expect(before.pageNotes.count == 2 && before.highlights.count == 2)

        let undoManager = undoManager()
        undoManager.beginUndoGrouping()
        workspace.remove([paper.id], undoManager: undoManager)
        undoManager.endUndoGrouping()
        #expect(try container.mainContext.fetch(FetchDescriptor<PageNote>()).isEmpty, "Page notes go with it")

        undoManager.undo()

        let restored = try #require(store.entry(id: before.id))
        #expect(Everything(restored) == before)
        #expect(restored.label(ofPage: 2) == "xi")
        #expect(restored.openQuestionCount == 0)
    }

    @Test func undoLeavesAPDFAloneThatWasAddedAgainMeanwhile() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Paper")
        let url = try #require(store.resolveFile(for: paper))
        let undoManager = undoManager()
        undoManager.beginUndoGrouping()
        workspace.remove([paper.id], undoManager: undoManager)
        undoManager.endUndoGrouping()

        let again = try #require(store.add(urls: [url]).first)
        undoManager.undo()

        #expect(try allEntries().map(\.id) == [again.id])
    }

    @Test func removingAnOpenPDFClosesItFirst() async throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Paper")
        let other = try entry(named: "Other")
        workspace.open(other)
        workspace.open(paper)
        let document = try #require(workspace.selectedDocument)
        await document.waitUntilLoaded()
        await workspace.documents[0].waitUntilLoaded()
        #expect(document.model != nil)

        workspace.remove([paper.id], undoManager: nil)

        #expect(workspace.documents.map(\.id) == [other.id])
        #expect(workspace.isShowingLibrary)
        #expect(preferences.stringArray(forKey: "openDocuments") == [other.id.uuidString])
        // A reader still holding the closed PDF shows its last title.
        #expect(document.title == "Paper")
        workspace.close(other.id)
    }

    @Test func aMissingFileCanBeRemovedWithoutAsking() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Gone")
        try FileManager.default.removeItem(at: URL(filePath: paper.lastKnownPath))

        workspace.openPDFs([paper])
        #expect(workspace.missingFileRequest == paper.id)
        #expect(workspace.documents.isEmpty)

        workspace.remove([paper.id], undoManager: nil)
        #expect(try allEntries().isEmpty)
    }

    // MARK: The confirmation

    @Test func theConfirmationSaysWhatGoesAndWhatStays() throws {
        let paper = try entry(named: "Paper")
        highlight(paper, "One", note: "Check this")
        highlight(paper, "Two")
        paper.bookmarkedPages = [2]

        let one = RemovalSummary([paper])
        #expect(one.title == "Remove \u{201C}Paper\u{201D} from your library?")
        #expect(one.message == "Its 2 highlights, 1 note and 1 bookmark in Sheaf are deleted. The PDF stays where it is, with the highlights and notes Sheaf saved into it.")

        let plain = try entry(named: "Plain")
        let other = try entry(named: "Other")
        let both = RemovalSummary([plain, other])
        #expect(both.title == "Remove 2 PDFs from your library?")
        #expect(both.message == "The PDFs themselves stay where they are on your Mac.")

        highlight(other, "Three")
        let mixed = RemovalSummary([plain, other])
        #expect(mixed.message == "Their 1 highlight in Sheaf is deleted. The PDFs stay where they are, with the highlights Sheaf saved into them.")

        // Page notes, answers and summaries are never in the file.
        let question = highlight(paper, "Why?", kind: .question)
        store.setAnswer("Found it", isAnswered: true, for: question)
        store.addPageNote(to: paper, pageIndex: 0, text: "The diagram")
        store.addPageNote(to: paper, pageIndex: 1, text: "The table")
        store.setSummary("About attention", for: paper)
        let everything = RemovalSummary([paper])
        #expect(everything.message == "Its 3 highlights, 1 note, 2 page notes, 1 answer, 1 summary and 1 bookmark in Sheaf are deleted. The PDF stays where it is, with the highlights and notes Sheaf saved into it. Its page notes, answer and summary are kept only in Sheaf, not in the file.")

        store.addPageNote(to: plain, pageIndex: 0, text: "Cover")
        store.setSummary("Plain", for: plain)
        let notesOnly = RemovalSummary([plain])
        #expect(notesOnly.message == "Its 1 page note and 1 summary in Sheaf are deleted. The PDF itself stays where it is on your Mac. Its page note and summary are kept only in Sheaf, not in the file.")
    }

    // MARK: Collections

    @Test func deletingACollectionAsksFirstAndUndoBringsItBack() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let first = store.createCollection(named: "Reading group")
        let thesis = store.createCollection(named: "Thesis")
        let paper = try entry(named: "Paper")
        let notes = try entry(named: "Notes")
        _ = try entry(named: "Other")
        store.move([paper, notes], to: thesis)
        workspace.libraryScope = .collection(thesis.id)
        let (id, colorIndex, createdAt) = (thesis.id, thesis.colorIndex, thesis.createdAt)

        // What the confirmation says.
        let summary = CollectionDeletionSummary(thesis)
        #expect(summary.title == "Delete the collection \u{201C}Thesis\u{201D}?")
        #expect(summary.message == "The 2 PDFs in it stay in your library, with their highlights and notes.")
        #expect(CollectionDeletionSummary(first).message == "It has no PDFs in it.")

        let undoManager = undoManager()
        undoManager.beginUndoGrouping()
        workspace.deleteCollection(id, undoManager: undoManager)
        undoManager.endUndoGrouping()

        #expect(store.collection(id: id) == nil)
        #expect(try allEntries().count == 3, "Its PDFs stay in the library")
        #expect(paper.collection == nil)
        #expect(workspace.libraryScope == .all)
        #expect(undoManager.undoActionName == "Delete Collection")

        // Meanwhile one of its PDFs goes in another collection: it stays there.
        store.move([notes], to: first)
        undoManager.undo()

        let restored = try #require(store.collection(id: id))
        #expect(restored.name == "Thesis")
        #expect(restored.colorIndex == colorIndex)
        #expect(restored.createdAt == createdAt)
        #expect(restored.items.map(\.id) == [paper.id])
        #expect(notes.collection?.id == first.id)
        // In its place in the left panel.
        #expect(store.allCollections().map(\.id) == [first.id, id])

        undoManager.redo()
        #expect(store.collection(id: id) == nil)
        #expect(paper.collection == nil)
    }

    // MARK: Renaming

    @Test func renamingUpdatesOpenReadersAndSpotlightAndCanBeUndone() async throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Paper")
        let record = highlight(paper, "Self-attention")
        workspace.open(paper)
        let document = try #require(workspace.selectedDocument)
        await document.waitUntilLoaded()
        let model = try #require(document.model)

        let undoManager = undoManager()
        undoManager.beginUndoGrouping()
        workspace.rename(paper.id, to: "  Attention Is All You Need ", undoManager: undoManager)
        undoManager.endUndoGrouping()

        #expect(paper.title == "Attention Is All You Need")
        #expect(document.title == "Attention Is All You Need")
        #expect(model.title == "Attention Is All You Need")
        // Only the title in Sheaf: the file keeps its name.
        #expect(store.resolveFile(for: paper)?.lastPathComponent == "Paper.pdf")
        guard case .indexed(let indexed) = index.changes.last else {
            Issue.record("Renaming didn't update Spotlight")
            return
        }
        #expect(indexed.map(\.id) == [record.id])
        #expect(indexed.map(\.pdfTitle) == ["Attention Is All You Need"])

        // An empty title changes nothing.
        workspace.rename(paper.id, to: "   ", undoManager: undoManager)
        #expect(paper.title == "Attention Is All You Need")

        undoManager.undo()
        #expect(paper.title == "Paper")
        #expect(model.title == "Paper")
        workspace.close(paper.id)
    }

    // MARK: Acting on a selection

    @Test func theMenuBarActsOnTheSelectionOrThePDFOnScreen() async throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let first = try entry(named: "First")
        let second = try entry(named: "Second")
        let third = try entry(named: "Third")

        workspace.librarySelection = [first.id, second.id]
        #expect(Set(workspace.commandTargets.map(\.id)) == [first.id, second.id])

        // The Highlights page doesn't show the list, so there's nothing to act on.
        workspace.libraryScope = .highlights
        #expect(workspace.commandTargets.isEmpty)
        workspace.libraryScope = .all

        workspace.open(third)
        #expect(workspace.commandTargets.map(\.id) == [third.id])
        workspace.showLibrary()
        #expect(workspace.commandTargets.count == 2)
        await workspace.documents[0].waitUntilLoaded()
        workspace.close(third.id)
    }

    @Test func starringAndCollectionsActOnEveryPDFInTheSelection() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let first = try entry(named: "First")
        let second = try entry(named: "Second")
        let selected = [first, second]

        workspace.setStarred(true, for: selected)
        #expect(selected.allSatisfy { $0.isStarred })

        // A new collection asks for its name first, then the PDFs go in it.
        workspace.requestNewCollection(for: selected)
        #expect(workspace.newCollectionRequest == [first.id, second.id])
        #expect(first.collection == nil)
        workspace.createCollection(named: " Thesis ", with: [first.id, second.id])
        let collection = try #require(first.collection)
        #expect(collection.name == "Thesis")
        #expect(second.collection?.id == collection.id)

        let other = store.createCollection(named: "Other")
        workspace.move(selected, to: other)
        #expect(selected.allSatisfy { $0.collection?.id == other.id })

        workspace.move(selected, to: nil)
        #expect(selected.allSatisfy { $0.collection == nil })

        workspace.requestRemoval(of: selected)
        #expect(workspace.removalRequest == [first.id, second.id])
        workspace.requestRename(first)
        #expect(workspace.renameRequest == first.id)
    }

    @Test func aDraggedPDFCarriesItsFileAndAMarkFromTheList() throws {
        let workspace = Workspace(library: store, preferences: preferences)
        let paper = try entry(named: "Paper")

        let provider = try #require(workspace.dragItem(for: paper))

        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.sheafLibraryPDF.identifier))
        #expect(provider.suggestedName == "Paper.pdf")
    }

    @Test func droppingPDFsOnACollectionAddsThemToIt() async throws {
        let paper = try entry(named: "Paper")
        let url = try #require(store.resolveFile(for: paper))
        let newFile = try TestFiles.pdf(named: "New.pdf", pages: ["new"])
        let research = store.createCollection(named: "Research")

        // As the left panel does with PDFs dragged from the list and from Finder.
        let added = await store.addFiles([url, newFile], to: research)

        #expect(added.count == 2)
        #expect(Set(research.items.map(\.id)) == Set(added.map(\.id)))
        #expect(added.contains { $0.id == paper.id })
    }

    // MARK: Narrow windows

    @Test func panelsShowOverThePageWhenTheyDontFitBesideIt() throws {
        let panels = ReaderPanels(preferences: preferences)
        #expect(panels.isBeside(.pages) && panels.isBeside(.highlights))

        panels.toggle(.pages)
        #expect(!panels.isShowing(.pages))
        #expect(preferences.object(forKey: "showsThumbnails") as? Bool == false)

        // Half a laptop screen: neither fits, and neither shows until asked.
        panels.setWidth(700)
        #expect(!panels.isShowing(.highlights))
        panels.toggle(.highlights)
        #expect(panels.isOver(.highlights))
        #expect(panels.isShowing(.highlights))
        // One at a time over the page.
        panels.toggle(.pages)
        #expect(panels.isOver(.pages))
        #expect(!panels.isOver(.highlights))
        #expect(panels.closeOverlay())
        #expect(!panels.closeOverlay())

        // Widening the window moves the panel over the page beside it.
        panels.toggle(.highlights)
        panels.setWidth(800)
        #expect(panels.isBeside(.highlights))
        #expect(!panels.isOver(.highlights))
        #expect(!panels.isShowing(.pages))
    }

    @Test func theTitleMenuListsTheFoldersAboveTheFile() {
        let folders = ReaderTitleMenu.folders(containing: URL(filePath: "/Users/reader/Papers/Attention.pdf"))
        #expect(folders.map { $0.path(percentEncoded: false) } == ["/Users/reader/Papers/", "/Users/reader/", "/Users/", "/"])
    }
}
