import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Editing highlights from the library's Highlights page. With the PDF
/// open, changes go through its reader (the page, saving and Undo work as
/// in the reader); with it closed, the library marks the file for saving
/// the next time it opens.
@MainActor
struct LibraryHighlightEditingTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let preferences: UserDefaults
    /// The library window's.
    private let libraryUndo = UndoManager()

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        preferences = try #require(UserDefaults(suiteName: "SheafHighlightEditing.\(UUID().uuidString)"))
        libraryUndo.groupsByEvent = false
    }

    /// A PDF in the library with a highlight over `text`, and a workspace.
    private func makeLibrary(pages: [String], highlighting text: String, kind: HighlightKind = .keyIdea)
        throws -> (Workspace, LibraryEntry, HighlightRecord, URL)
    {
        let url = try TestFiles.pdf(pages: pages)
        let entry = try #require(store.add(urls: [url]).first)
        let snapshot = try TestFiles.highlight(of: text, in: url, kind: kind)
        let record = store.addHighlight(
            to: entry, pageIndex: snapshot.pageIndex, kind: kind, text: text, rects: snapshot.rects
        )
        return (Workspace(library: store, preferences: preferences), entry, record, url)
    }

    private func step(_ change: () -> Void) {
        libraryUndo.beginUndoGrouping()
        change()
        libraryUndo.endUndoGrouping()
    }

    private func annotations(of id: UUID, in document: PDFDocument) -> [PDFAnnotation] {
        (0..<document.pageCount).flatMap { document.page(at: $0)?.annotations ?? [] }.filter { PDFHighlights.id(of: $0) == id }
    }

    private static func hex(_ color: NSColor?) -> UInt32? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { UInt32(($0 * 255).rounded()) }
        return parts[0] << 16 | parts[1] << 8 | parts[2]
    }

    // MARK: The PDF is open

    @Test func withThePDFOpenChangesGoThroughItsReader() async throws {
        let (workspace, entry, record, _) = try makeLibrary(pages: ["Attention is all you need"], highlighting: "Attention")
        workspace.open(entry)
        let document = try #require(workspace.selectedDocument)
        try await waitUntil { document.model != nil }
        let reader = try #require(document.model)
        let readerUndo = UndoManager()
        reader.undoManager = readerUndo
        workspace.showLibrary()
        let id = record.id

        step { workspace.setNote("Why it matters", forHighlight: id, undoManager: libraryUndo) }
        step { workspace.setKind(.evidence, forHighlight: id, undoManager: libraryUndo) }
        step { workspace.setAnswer("n/a", isAnswered: true, forHighlight: id, undoManager: libraryUndo) }

        // The page shows it, as if changed in the reader.
        let lines = annotations(of: id, in: reader.document)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.contents == "Why it matters" })
        #expect(lines.allSatisfy { Self.hex($0.color) == HighlightKind.evidence.pageColorHex })
        // Undo is in the library's window, where the change was made.
        #expect(libraryUndo.undoActionName == "Answer Question")
        #expect(!readerUndo.canUndo)

        libraryUndo.undo()
        libraryUndo.undo()
        #expect(record.kind == .keyIdea)
        #expect(annotations(of: id, in: reader.document).allSatisfy { Self.hex($0.color) == HighlightKind.keyIdea.pageColorHex })
        libraryUndo.redo()
        #expect(record.kind == .evidence)

        // Saving works as in the reader.
        await reader.saveAndWait()
        #expect(!entry.needsFileSave)

        // Closing the PDF takes its changes out of the library's Undo too.
        workspace.close(entry.id)
        #expect(!libraryUndo.canUndo)
        await document.waitUntilLoaded()
    }

    @Test func deletingWithThePDFOpenCanBeUndone() async throws {
        let (workspace, entry, record, _) = try makeLibrary(pages: ["Attention is all you need"], highlighting: "Attention", kind: .question)
        workspace.open(entry)
        let document = try #require(workspace.selectedDocument)
        try await waitUntil { document.model != nil }
        let reader = try #require(document.model)
        let id = record.id
        step { workspace.setAnswer("Found it", isAnswered: true, forHighlight: id, undoManager: libraryUndo) }

        step { workspace.deleteHighlight(id: id, undoManager: libraryUndo) }
        #expect(reader.highlight(id: id) == nil)
        #expect(annotations(of: id, in: reader.document).isEmpty)
        #expect(libraryUndo.undoActionName == "Delete Highlight")

        libraryUndo.undo()
        let restored = try #require(reader.highlight(id: id))
        #expect(restored.answer == "Found it")
        #expect(!annotations(of: id, in: reader.document).isEmpty)

        await reader.saveAndWait()
        workspace.close(entry.id)
        await document.waitUntilLoaded()
    }

    // MARK: The PDF is closed

    @Test func withThePDFClosedTheFileIsMarkedForSaving() throws {
        let (workspace, entry, record, _) = try makeLibrary(pages: ["Attention is all you need"], highlighting: "Attention")
        entry.needsFileSave = false
        let id = record.id

        step { workspace.setNote("Why it matters", forHighlight: id, undoManager: libraryUndo) }
        #expect(record.note == "Why it matters")
        #expect(entry.needsFileSave)
        #expect(libraryUndo.undoActionName == "Edit Note")

        step { workspace.setKind(.definition, forHighlight: id, undoManager: libraryUndo) }
        #expect(record.kind == .definition)
        libraryUndo.undo()
        #expect(record.kind == .keyIdea)
        libraryUndo.undo()
        #expect(record.note.isEmpty)
        libraryUndo.redo()
        #expect(record.note == "Why it matters")

        // Answers stay in the library: nothing more to save.
        entry.needsFileSave = false
        step { workspace.setKind(.question, forHighlight: id, undoManager: libraryUndo) }
        entry.needsFileSave = false
        step { workspace.setAnswer("Found it", isAnswered: true, forHighlight: id, undoManager: libraryUndo) }
        #expect(record.isAnsweredQuestion)
        #expect(!entry.needsFileSave)
        #expect(workspace.documents.isEmpty)
    }

    @Test func deletingWithThePDFClosedCanBeUndone() throws {
        let (workspace, entry, record, _) = try makeLibrary(pages: ["Attention is all you need"], highlighting: "Attention", kind: .question)
        let id = record.id
        step { workspace.setAnswer("Found it", isAnswered: true, forHighlight: id, undoManager: libraryUndo) }

        step { workspace.deleteHighlight(id: id, undoManager: libraryUndo) }
        #expect(store.highlight(id: id) == nil)
        // The next save takes it out of the file.
        #expect(entry.removedHighlightIDs == [id])
        #expect(entry.needsFileSave)

        libraryUndo.undo()
        let restored = try #require(store.highlight(id: id))
        #expect(restored.entry?.id == entry.id)
        #expect(restored.answer == "Found it")
        #expect(entry.removedHighlightIDs.isEmpty)

        libraryUndo.redo()
        #expect(store.highlight(id: id) == nil)
    }

    @Test func aPDFOpenedAfterAChangeShowsItAndSavesIt() async throws {
        let (workspace, entry, record, url) = try makeLibrary(pages: ["Attention is all you need"], highlighting: "Attention")
        // The highlight is in the file as it was.
        #expect(PDFHighlightWriter.write([HighlightSnapshot(record)], to: url) == .saved)
        entry.needsFileSave = false
        let id = record.id

        step { workspace.setKind(.evidence, forHighlight: id, undoManager: libraryUndo) }
        step { workspace.setNote("Cite this", forHighlight: id, undoManager: libraryUndo) }

        workspace.open(entry)
        let document = try #require(workspace.selectedDocument)
        try await waitUntil { document.model != nil }
        let reader = try #require(document.model)

        let lines = annotations(of: id, in: reader.document)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { Self.hex($0.color) == HighlightKind.evidence.pageColorHex && $0.contents == "Cite this" })

        await reader.saveAndWait()
        let saved = try #require(PDFDocument(url: url))
        let savedLines = annotations(of: id, in: saved)
        #expect(!savedLines.isEmpty)
        #expect(savedLines.allSatisfy { Self.hex($0.color) == HighlightKind.evidence.pageColorHex && $0.contents == "Cite this" })
        #expect(!entry.needsFileSave)

        workspace.close(entry.id)
        await document.waitUntilLoaded()
    }

    @Test func undoAfterOpeningThePDFGoesThroughItsReader() async throws {
        let (workspace, entry, record, _) = try makeLibrary(pages: ["Attention is all you need"], highlighting: "Attention")
        let id = record.id
        // Deleted while closed…
        step { workspace.deleteHighlight(id: id, undoManager: libraryUndo) }

        // …and brought back once the PDF is open: it's back on the page too.
        workspace.open(entry)
        let document = try #require(workspace.selectedDocument)
        try await waitUntil { document.model != nil }
        let reader = try #require(document.model)
        #expect(reader.highlight(id: id) == nil)

        libraryUndo.undo()
        #expect(reader.highlight(id: id) != nil)
        #expect(!annotations(of: id, in: reader.document).isEmpty)

        await reader.saveAndWait()
        workspace.close(entry.id)
        await document.waitUntilLoaded()
    }
}
