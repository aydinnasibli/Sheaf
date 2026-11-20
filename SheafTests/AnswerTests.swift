import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Answering Question highlights: open questions get fewer, answers are
/// kept in the library (never in the file), and Undo works.
@MainActor
struct AnswerTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let undo = UndoManager()

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        undo.groupsByEvent = false
    }

    private func makeEntry(title: String = "Paper") -> LibraryEntry {
        let entry = LibraryEntry(title: title, path: "/Users/test/\(title).pdf", pageCount: 12)
        container.mainContext.insert(entry)
        return entry
    }

    @discardableResult
    private func addHighlight(to entry: LibraryEntry, kind: HighlightKind = .question, text: String = "Why?") -> HighlightRecord {
        store.addHighlight(to: entry, pageIndex: 3, kind: kind, text: text, rects: [CGRect(x: 72, y: 600, width: 200, height: 14)])
    }

    private func makeReader(pages: [String]) throws -> (ReaderModel, LibraryEntry, URL) {
        let url = try TestFiles.pdf(pages: pages)
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences)
        model.undoManager = undo
        return (model, entry, url)
    }

    private func question(_ text: String, in model: ReaderModel) throws -> HighlightRecord {
        model.pdfView.currentSelection = try #require(model.document.findString(text, withOptions: []).first)
        step { model.highlightSelection(as: .question) }
        return try #require(model.highlights.first { $0.text == text })
    }

    private func step(_ change: () -> Void) {
        undo.beginUndoGrouping()
        change()
        undo.endUndoGrouping()
    }

    // MARK: Open questions

    @Test func answeredQuestionsDropOutOfOpenQuestions() {
        let entry = makeEntry()
        let first = addHighlight(to: entry)
        let second = addHighlight(to: entry, text: "How?")
        addHighlight(to: entry, kind: .keyIdea, text: "Not a question")
        #expect(entry.openQuestionCount == 2)
        #expect(LibraryFilter.openQuestions.matches(entry))

        store.setAnswer("  Because of attention.  ", isAnswered: true, for: first)
        #expect(first.answer == "Because of attention.")
        #expect(first.isAnsweredQuestion)
        #expect(entry.openQuestionCount == 1)
        #expect(LibraryFilter.openQuestions.matches(entry))

        // Answered without writing anything still counts as answered.
        store.setAnswer("", isAnswered: true, for: second)
        #expect(entry.openQuestionCount == 0)
        #expect(!entry.hasOpenQuestions)
        #expect(!LibraryFilter.openQuestions.matches(entry))

        // Open again, it's back on the list.
        store.setAnswer("", isAnswered: false, for: second)
        #expect(entry.openQuestionCount == 1)
    }

    @Test func anAnswerOnlyCountsOnAQuestion() {
        let entry = makeEntry()
        let record = addHighlight(to: entry)
        store.setAnswer("Found it", isAnswered: true, for: record)

        store.setKind(.keyIdea, for: record)
        #expect(!record.isAnsweredQuestion)
        #expect(!record.isOpenQuestion)
        #expect(SpotlightHighlight(record)?.answer == nil)

        // Back to a question, the answer is still there.
        store.setKind(.question, for: record)
        #expect(record.isAnsweredQuestion)
        #expect(record.answer == "Found it")
    }

    @Test func answersAreNotSomethingToSaveIntoThePDF() {
        let entry = makeEntry()
        let record = addHighlight(to: entry)
        entry.needsFileSave = false

        store.setAnswer("Found it", isAnswered: true, for: record)

        #expect(!entry.needsFileSave)
    }

    // MARK: In the reader

    @Test func answeringInTheReaderCanBeUndone() throws {
        let (model, entry, _) = try makeReader(pages: ["Why does attention work so well"])
        let record = try question("attention work", in: model)
        #expect(entry.openQuestionCount == 1)

        step { model.setAnswer("It relates every position to every other.", isAnswered: true, for: record) }
        #expect(undo.undoActionName == "Answer Question")
        #expect(record.isAnswered)
        #expect(entry.openQuestionCount == 0)

        step { model.setAnswer("It relates all positions.", isAnswered: true, for: record) }
        #expect(undo.undoActionName == "Edit Answer")

        step { model.setAnswer(record.answer, isAnswered: false, for: record) }
        #expect(undo.undoActionName == "Mark as Unanswered")
        #expect(entry.openQuestionCount == 1)

        undo.undo()
        #expect(record.isAnswered)
        #expect(record.answer == "It relates all positions.")
        undo.undo()
        #expect(record.answer == "It relates every position to every other.")
        undo.undo()
        #expect(!record.isAnswered)
        #expect(record.answer.isEmpty)
        undo.redo()
        #expect(record.isAnswered)
    }

    @Test func undoingADeleteBringsTheAnswerBack() throws {
        let (model, _, _) = try makeReader(pages: ["Why does attention work so well"])
        let record = try question("attention work", in: model)
        let id = record.id
        step { model.setAnswer("Found it", isAnswered: true, for: record) }

        step { model.delete(record) }
        #expect(model.highlight(id: id) == nil)
        undo.undo()

        let restored = try #require(model.highlight(id: id))
        #expect(restored.isAnswered)
        #expect(restored.answer == "Found it")
    }

    @Test func theAnswerIsNotWrittenIntoTheFile() async throws {
        let (model, _, url) = try makeReader(pages: ["Why does attention work so well"])
        let record = try question("attention work", in: model)
        step { model.setNote("Ask in the seminar", for: record) }
        step { model.setAnswer("Found it in chapter 3", isAnswered: true, for: record) }

        await model.saveAndWait()

        let saved = try #require(PDFDocument(url: url))
        let contents = (saved.page(at: 0)?.annotations ?? []).filter { PDFHighlights.id(of: $0) == record.id }.map(\.contents)
        #expect(contents == ["Ask in the seminar"])
    }

    @Test func theReadersMarkdownIncludesAnswers() throws {
        let (model, _, _) = try makeReader(pages: ["Why does attention work and what about recurrence"])
        let answered = try question("attention work", in: model)
        _ = try question("recurrence", in: model)
        step { model.setAnswer("It relates all positions.\nSee section 3.", isAnswered: true, for: answered) }

        let markdown = model.markdownExport()

        #expect(markdown.contains(
            "- \u{201C}attention work\u{201D} (Paper, p. 1)\n  - Answer: It relates all positions.\n    See section 3.\n"
        ))
        // The open one has no answer line.
        #expect(markdown.contains("- \u{201C}recurrence\u{201D} (Paper, p. 1)"))
        #expect(!markdown.contains("recurrence\u{201D} (Paper, p. 1)\n  - Answer"))
    }

    // MARK: Spotlight

    @Test func spotlightDescribesTheAnswer() throws {
        let entry = makeEntry(title: "Contract")
        let record = addHighlight(to: entry)
        store.setNote("Ask legal", for: record)

        store.setAnswer("Clause 4 covers it", isAnswered: true, for: record)
        #expect(try #require(SpotlightHighlight(record)).summary
            == "Ask legal\nAnswer: Clause 4 covers it\nQuestion on page 4 of \u{201C}Contract\u{201D}")

        store.setAnswer("", isAnswered: true, for: record)
        #expect(try #require(SpotlightHighlight(record)).summary
            == "Ask legal\nAnswered\nQuestion on page 4 of \u{201C}Contract\u{201D}")

        store.setAnswer("", isAnswered: false, for: record)
        #expect(try #require(SpotlightHighlight(record)).summary == "Ask legal\nQuestion on page 4 of \u{201C}Contract\u{201D}")
    }

    @Test func answeringUpdatesSpotlight() throws {
        let index = FakeHighlightIndex()
        store.searchIndex = index
        let record = addHighlight(to: makeEntry())

        store.setAnswer("Found it", isAnswered: true, for: record)

        guard case .indexed(let highlights) = index.changes.last else {
            Issue.record("Answering didn't update Spotlight")
            return
        }
        #expect(highlights.map(\.answer) == ["Found it"])
    }

    // MARK: Removing a PDF

    @Test func undoingRemoveFromLibraryKeepsAnswers() throws {
        let entry = makeEntry()
        let record = addHighlight(to: entry)
        store.setAnswer("Found it", isAnswered: true, for: record)

        let removed = store.remove([entry])
        let restored = try #require(store.restore(removed).first)

        let back = try #require(restored.highlights.first)
        #expect(back.isAnswered)
        #expect(back.answer == "Found it")
    }
}
