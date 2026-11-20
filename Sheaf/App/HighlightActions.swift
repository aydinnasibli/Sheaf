import Foundation

/// Changes to highlights made from the library's Highlights and Notes
/// pages: a note, a color, an answer, or deleting. Each reaches the library
/// and, for notes, colors and deleting, the PDF file too:
///
/// - For a PDF that's open, in the main window or its own, the change goes
///   through its reader, as if made there: the page shows it and the file
///   is saved as usual.
/// - For a PDF that isn't open, the library changes and marks the file as
///   needing a save; it's brought up to date the next time the PDF opens.
///
/// Undo is registered with `undoManager` (the library window's), on the
/// workspace rather than on a reader, so it outlasts the PDF being opened,
/// left or closed. Each Undo looks again at whether the PDF is open by then.
extension Workspace {
    /// The reader of a PDF that's open and loaded, in any window, if this
    /// highlight's is.
    func openReader(for record: HighlightRecord) -> ReaderModel? {
        record.entry.flatMap { openReader(forPDF: $0.id) }
    }

    func openReader(forPDF id: UUID) -> ReaderModel? {
        allDocuments.first { $0.id == id }?.model
    }

    func setNote(_ note: String, forHighlight id: UUID, undoManager: UndoManager?) {
        guard let record = library.highlight(id: id) else { return }
        let old = record.note
        guard note.trimmingCharacters(in: .whitespacesAndNewlines) != old else { return }
        if let reader = openReader(for: record) {
            reader.withoutRegisteringUndo { reader.setNote(note, for: record) }
        } else {
            library.setNote(note, for: record)
        }
        registerUndo("Edit Note", with: undoManager) { workspace, undoManager in
            workspace.setNote(old, forHighlight: id, undoManager: undoManager)
        }
    }

    func setKind(_ kind: HighlightKind, forHighlight id: UUID, undoManager: UndoManager?) {
        guard let record = library.highlight(id: id) else { return }
        let old = record.kind
        guard kind != old else { return }
        if let reader = openReader(for: record) {
            reader.withoutRegisteringUndo { reader.setKind(kind, for: record) }
        } else {
            library.setKind(kind, for: record)
        }
        registerUndo("Change Highlight Color", with: undoManager) { workspace, undoManager in
            workspace.setKind(old, forHighlight: id, undoManager: undoManager)
        }
    }

    /// Marks a question answered, with her answer (it may be empty), or open
    /// again. Answers stay in the library, so the file isn't touched.
    func setAnswer(_ answer: String, isAnswered: Bool, forHighlight id: UUID, undoManager: UndoManager?) {
        guard let record = library.highlight(id: id) else { return }
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = (answer: record.answer, isAnswered: record.isAnswered)
        guard trimmed != old.answer || isAnswered != old.isAnswered else { return }
        if let reader = openReader(for: record) {
            reader.withoutRegisteringUndo { reader.setAnswer(trimmed, isAnswered: isAnswered, for: record) }
        } else {
            library.setAnswer(trimmed, isAnswered: isAnswered, for: record)
        }
        let actionName = ReaderModel.answerActionName(wasAnswered: old.isAnswered, isAnswered: isAnswered)
        registerUndo(actionName, with: undoManager) { workspace, undoManager in
            workspace.setAnswer(old.answer, isAnswered: old.isAnswered, forHighlight: id, undoManager: undoManager)
        }
    }

    /// Deletes a highlight; Undo brings it back with its note, answer and
    /// page label.
    func deleteHighlight(id: UUID, undoManager: UndoManager?) {
        guard let record = library.highlight(id: id), let entryID = record.entry?.id else { return }
        let snapshot = HighlightSnapshot(record)
        if let reader = openReader(for: record) {
            reader.withoutRegisteringUndo { reader.delete(record) }
        } else {
            library.delete(record)
        }
        registerUndo("Delete Highlight", with: undoManager) { workspace, undoManager in
            workspace.restoreHighlight(snapshot, entryID: entryID, undoManager: undoManager)
        }
    }

    /// Undo of `deleteHighlight`.
    private func restoreHighlight(_ snapshot: HighlightSnapshot, entryID: UUID, undoManager: UndoManager?) {
        // Removed from the library meanwhile: there's nothing to put it back in.
        guard let entry = library.entry(id: entryID), library.highlight(id: snapshot.id) == nil else { return }
        if let reader = openReader(forPDF: entryID) {
            reader.withoutRegisteringUndo { reader.restoreDeleted(snapshot) }
        } else {
            library.restoreHighlight(snapshot, to: entry)
        }
        let id = snapshot.id
        registerUndo("Delete Highlight", with: undoManager) { workspace, undoManager in
            workspace.deleteHighlight(id: id, undoManager: undoManager)
        }
    }

    private func registerUndo(
        _ actionName: String, with undoManager: UndoManager?, _ action: @escaping (Workspace, UndoManager?) -> Void
    ) {
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            action(workspace, undoManager)
        }
        undoManager?.setActionName(actionName)
    }
}
