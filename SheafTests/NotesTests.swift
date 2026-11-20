import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Notes while reading: clicking a highlight, the note shortcut, page notes
/// and the summary.
@MainActor
struct NotesTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let undo = UndoManager()

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        // Explicit groups, one per change (the app groups each user action itself).
        undo.groupsByEvent = false
    }

    private func makeReader(pages: [String]) throws -> (ReaderModel, LibraryEntry) {
        let url = try TestFiles.pdf(pages: pages)
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences)
        model.undoManager = undo
        return (model, entry)
    }

    private func highlight(_ text: String, in model: ReaderModel, as kind: HighlightKind = .keyIdea) throws -> HighlightRecord {
        model.pdfView.currentSelection = try #require(model.document.findString(text, withOptions: []).first)
        step { model.highlightSelection(as: kind) }
        return try #require(model.highlights.first { $0.text == text })
    }

    /// One undo step.
    private func step(_ change: () -> Void) {
        undo.beginUndoGrouping()
        change()
        undo.endUndoGrouping()
    }

    // MARK: Highlights on the page

    @Test func clickingAHighlightSelectsItAndClickingElsewhereDoesNot() throws {
        let (model, _) = try makeReader(pages: ["The quick brown fox jumps over"])
        let record = try highlight("brown fox", in: model, as: .question)
        let page = try #require(model.document.page(at: 0))
        model.selectedHighlightID = nil
        let line = try #require(record.rects.first)

        model.pageClicked(page, at: CGPoint(x: line.midX, y: line.midY))
        #expect(model.selectedHighlightID == record.id)

        model.pageClicked(page, at: CGPoint(x: 10, y: 10))
        #expect(model.selectedHighlightID == nil)
    }

    @Test func selectingAHighlightLetsItsColorThroughTheFilter() throws {
        let (model, _) = try makeReader(pages: ["The quick brown fox jumps over"])
        let record = try highlight("brown fox", in: model, as: .question)
        model.panelFilter = [.evidence]

        model.select(record)

        #expect(model.panelFilter == [.evidence, .question])
        #expect(model.panelGroups.flatMap(\.items).map(\.id) == [record.id])
    }

    @Test func theNoteShortcutOpensTheNoteOfTheHighlightJustMade() throws {
        let (model, _) = try makeReader(pages: ["Alpha idea and beta question"])
        #expect(!model.editNoteOfHighlight(), "No highlights yet")

        _ = try highlight("Alpha idea", in: model)
        let latest = try highlight("beta question", in: model, as: .question)
        #expect(model.selectedHighlightID == latest.id)

        // With the panel showing, its card starts editing.
        model.isHighlightsPanelVisible = true
        #expect(model.editNoteOfHighlight())
        #expect(model.pendingNoteEditID == latest.id)

        // In focus mode it's a popover instead (which needs a window on screen).
        model.pendingNoteEditID = nil
        model.isHighlightsPanelVisible = false
        #expect(model.editNoteOfHighlight())
        #expect(model.pendingNoteEditID == nil)
    }

    // MARK: Page notes

    @Test func pageNotesAreKeptInTheLibraryWithUndo() throws {
        let (model, entry) = try makeReader(pages: ["A slide", "A diagram", "The end"])
        #expect(!model.hasPageNote(onPage: 1))

        step { model.setPageNote("  Three stages of the model  ", onPage: 1) }
        #expect(undo.undoActionName == "Add Page Note")
        let note = try #require(model.pageNote(onPage: 1))
        #expect(note.text == "Three stages of the model")
        #expect(entry.pageNotes.map(\.id) == [note.id])
        #expect(model.hasPageNote(onPage: 1))

        step { model.setPageNote("Four stages", onPage: 1) }
        #expect(undo.undoActionName == "Edit Page Note")
        #expect(model.pageNote(onPage: 1)?.text == "Four stages")

        // Emptying a note deletes it.
        step { model.setPageNote("", onPage: 1) }
        #expect(undo.undoActionName == "Delete Page Note")
        #expect(model.pageNotes.isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PageNote>()).isEmpty)

        undo.undo()
        #expect(model.pageNote(onPage: 1)?.text == "Four stages")
        #expect(model.pageNote(onPage: 1)?.id == note.id)
        undo.undo()
        #expect(model.pageNote(onPage: 1)?.text == "Three stages of the model")
        undo.undo()
        #expect(model.pageNotes.isEmpty)
        undo.redo()
        #expect(model.pageNote(onPage: 1)?.text == "Three stages of the model")

        // Kept in the library only: nothing to write into the PDF.
        #expect(!entry.needsFileSave)
        #expect(PDFHighlights.ids(in: model.document).isEmpty)
    }

    @Test func deletingAPageNoteCanBeUndone() throws {
        let (model, _) = try makeReader(pages: ["A slide"])
        step { model.setPageNote("Remember this slide", onPage: 0) }
        let note = try #require(model.pageNote(onPage: 0))

        step { model.deletePageNote(note) }
        #expect(model.pageNotes.isEmpty)
        undo.undo()
        #expect(model.pageNote(onPage: 0)?.text == "Remember this slide")
    }

    @Test func pageNotesShowUnderTheirPageInThePanel() throws {
        let (model, _) = try makeReader(pages: ["First page text", "Second page", "Third page"])
        _ = try highlight("First page", in: model)
        step { model.setPageNote("About the diagram", onPage: 2) }

        #expect(model.panelGroups.map(\.page) == [0, 2])
        #expect(model.panelGroups.last?.note?.text == "About the diagram")

        // Add Page Note with the panel showing: an empty note to type in.
        model.isHighlightsPanelVisible = true
        model.editPageNote(onPage: 1)
        #expect(model.pendingPageNoteEdit == 1)
        #expect(model.panelGroups.map(\.page) == [0, 1, 2])
        #expect(model.panelGroups[1].hasDraftNote)
        // Left empty, it goes away.
        step { model.setPageNote("", onPage: 1) }
        #expect(model.panelGroups.map(\.page) == [0, 2])

        // Page notes have no color, so a color filter hides them.
        model.panelFilter = [.keyIdea]
        #expect(model.panelGroups.map(\.page) == [0])
    }

    // MARK: Summary

    @Test func theSummaryIsKeptWithUndo() throws {
        let (model, entry) = try makeReader(pages: ["Some text"])
        step { model.setSummary("  Argues that attention is all you need.  ") }
        #expect(undo.undoActionName == "Edit Summary")
        #expect(entry.summary == "Argues that attention is all you need.")
        #expect(model.summary == entry.summary)

        step { model.setSummary("Use for chapter 2.") }
        undo.undo()
        #expect(entry.summary == "Argues that attention is all you need.")
        undo.undo()
        #expect(entry.summary.isEmpty)
        undo.redo()
        #expect(entry.summary == "Argues that attention is all you need.")
        #expect(!entry.needsFileSave)
    }

    @Test func markdownIncludesTheSummaryAndPageNotes() throws {
        let (model, _) = try makeReader(pages: ["Alpha idea", "A slide"])
        #expect(!model.hasAnythingToExport)
        step { model.setSummary("What it\u{2019}s about.\nSecond paragraph.") }
        step { model.setPageNote("The three stages\nand a fourth", onPage: 1) }
        #expect(model.hasAnythingToExport)

        let markdown = model.markdownExport()

        #expect(markdown.hasPrefix("# Paper\n\n## My summary\n\nWhat it\u{2019}s about.\nSecond paragraph.\n"))
        #expect(markdown.contains("## Page notes\n\n- The three stages\n  and a fourth (Paper, p. 2)"))
        #expect(!markdown.contains("No highlights yet."))
    }

    @Test func notesCountForTheLibrarysNotesPage() throws {
        let (model, entry) = try makeReader(pages: ["Alpha idea here", "Second"])
        let record = try highlight("Alpha idea", in: model)
        #expect(entry.notesCount == 0)
        step { model.setNote("Why it matters", for: record) }
        step { model.setPageNote("A note", onPage: 1) }
        step { model.setSummary("A summary") }
        #expect(entry.notesCount == 3)
    }

    // MARK: Typing that isn't saved yet

    /// The text of the PDF file's annotations for a highlight.
    private func notesInFile(of id: UUID, at url: URL) throws -> [String] {
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount)
            .flatMap { document.page(at: $0)?.annotations ?? [] }
            .filter { PDFHighlights.id(of: $0) == id }
            .compactMap(\.contents)
    }

    @Test func whatsBeingTypedIsSavedWhenThePDFCloses() async throws {
        let (model, entry) = try makeReader(pages: ["The quick brown fox jumps over", "A slide"])
        let record = try highlight("brown fox", in: model, as: .question)
        let id = record.id
        // Typed, with neither Return nor a click elsewhere.
        model.keepDraft("Check the source", for: .note(id))
        model.keepDraft("Aesop", for: .answer(id))
        model.keepDraft("The three stages", for: .pageNote(1))
        model.keepDraft("About foxes", for: .summary)

        step { model.close() }

        #expect(record.note == "Check the source")
        #expect(record.isAnsweredQuestion && record.answer == "Aesop")
        #expect(entry.pageNotes.map(\.text) == ["The three stages"])
        #expect(entry.summary == "About foxes")
        // The note reaches the file too.
        await model.saveAndWait()
        let url = try #require(model.fileURL)
        #expect(try notesInFile(of: id, at: url).allSatisfy { $0 == "Check the source" })
        #expect(try !notesInFile(of: id, at: url).isEmpty)
    }

    @Test func whatsBeingTypedIsSavedWhenSheafQuitsOrThePDFLeavesTheScreen() async throws {
        let (model, entry) = try makeReader(pages: ["The quick brown fox jumps over"])
        let record = try highlight("brown fox", in: model)

        // Quitting saves drafts (the quit flush calls this), and the field
        // can go on being typed in.
        model.keepDraft("About foxes", for: .summary)
        step { model.saveDrafts() }
        #expect(entry.summary == "About foxes")
        model.keepDraft("About foxes and dogs", for: .summary)
        step { model.saveDraft(.summary) }
        #expect(entry.summary == "About foxes and dogs")
        // Saved once: nothing more to save.
        step { model.saveDraft(.summary) }
        step { model.saveDrafts() }
        #expect(entry.summary == "About foxes and dogs")

        // Leaving the PDF (another one shown, the window closed).
        model.keepDraft("Why it matters", for: .note(record.id))
        step { model.suspend() }
        #expect(record.note == "Why it matters")
        await model.saveAndWait()
        step { model.close() }
    }

    @Test func draftsLeftWithEscOrWithNothingToSaveOnChangeNothing() async throws {
        let (model, entry) = try makeReader(pages: ["The quick brown fox jumps over the lazy dog"])
        let question = try highlight("brown fox", in: model, as: .question)
        let deleted = try highlight("lazy dog", in: model)
        let deletedID = deleted.id

        // Esc.
        model.keepDraft("Never mind", for: .note(question.id))
        model.discardDraft(.note(question.id))
        // An empty answer leaves the question open.
        model.keepDraft("  ", for: .answer(question.id))
        // A highlight deleted (by Undo, say) while its note was being typed.
        model.keepDraft("Gone", for: .note(deletedID))
        step { model.delete(deleted) }
        // An empty page note that was never written.
        model.pageNoteDraftPage = 0
        model.keepDraft("", for: .pageNote(0))

        step { model.close() }

        #expect(question.note.isEmpty)
        #expect(question.isOpenQuestion)
        #expect(store.highlight(id: deletedID) == nil)
        #expect(entry.pageNotes.isEmpty)
        #expect(model.pageNoteDraftPage == nil)
        await model.saveAndWait()
    }

    @Test func whatsBeingTypedIsSavedWhenItsWindowCloses() async throws {
        let url = try TestFiles.pdf(pages: ["The quick brown fox jumps over"])
        let entry = try #require(store.add(urls: [url]).first)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let workspace = Workspace(library: store, preferences: preferences)
        workspace.openInNewWindow(entry)
        #expect(workspace.ownWindowDidAppear(entry.id))
        let document = try #require(workspace.windowedDocument(id: entry.id))
        try await waitUntil { document.model != nil }
        let model = try #require(document.model)

        model.keepDraft("Written in its own window", for: .pageNote(0))
        workspace.ownWindowDidClose(entry.id)

        #expect(workspace.windowedDocuments.isEmpty)
        #expect(entry.pageNotes.map(\.text) == ["Written in its own window"])
        await document.waitUntilLoaded()
    }
}
