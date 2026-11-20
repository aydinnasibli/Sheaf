import Foundation

/// A field in the Highlights panel she can type in.
enum DraftField: Hashable {
    /// A highlight's note.
    case note(UUID)
    /// A question's answer.
    case answer(UUID)
    /// A page's note, by page (0-based).
    case pageNote(Int)
    /// "My summary".
    case summary
}

/// What she's typing in the Highlights panel, kept here so it's never lost.
/// Each field hands over its text as she types (`keepDraft`) and saves it
/// with Return or when she clicks elsewhere (`saveDraft`). Anything not saved
/// by then is saved by `saveDrafts()`, which also saves the popover's note:
/// when Sheaf quits, the PDF closes or leaves the screen (its window closes,
/// another PDF is shown), or the notes are exported. So a note being typed
/// is kept even when its field goes away without a chance to save it.
extension ReaderModel {
    /// The text being typed in a field, as it is now.
    func keepDraft(_ text: String, for field: DraftField) {
        drafts[field] = text
    }

    /// Esc: forgets what was typed.
    func discardDraft(_ field: DraftField) {
        drafts[field] = nil
    }

    /// Saves what was typed in a field, if it isn't saved yet.
    func saveDraft(_ field: DraftField) {
        guard let text = drafts.removeValue(forKey: field) else { return }
        save(text, for: field)
    }

    /// Saves everything being typed: in the popover over the page, and in
    /// the panel's notes, answers and summary.
    func saveDrafts() {
        // The popover saves its note (and answer) as it closes.
        popover.close()
        let waiting = drafts
        drafts = [:]
        for (field, text) in waiting {
            save(text, for: field)
        }
    }

    private func save(_ text: String, for field: DraftField) {
        switch field {
        case .note(let id):
            // Deleted meanwhile (by Undo, say): there's nothing to save it on.
            if let record = highlight(id: id) { setNote(text, for: record) }
        case .answer(let id):
            guard let record = highlight(id: id) else { return }
            // Leaving an empty answer leaves an open question open.
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty || record.isAnswered {
                setAnswer(answer, isAnswered: true, for: record)
            }
        case .pageNote(let page):
            setPageNote(text, onPage: page)
        case .summary:
            setSummary(text)
        }
    }
}
