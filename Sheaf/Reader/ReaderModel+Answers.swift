import Foundation

/// Answering Question highlights while reading. Answers are kept in Sheaf's
/// library only, like page notes: nothing is written into the PDF, so an
/// answer never schedules a save.
extension ReaderModel {
    /// Marks a question answered, with her answer (it may be empty), or open
    /// again. Undo puts back what it was.
    func setAnswer(_ answer: String, isAnswered: Bool, for record: HighlightRecord) {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = (answer: record.answer, isAnswered: record.isAnswered)
        guard answer != old.answer || isAnswered != old.isAnswered, let store else { return }
        let id = record.id
        store.setAnswer(answer, isAnswered: isAnswered, for: record)
        registerUndo(Self.answerActionName(wasAnswered: old.isAnswered, isAnswered: isAnswered)) { model in
            if let record = model.highlight(id: id) {
                model.setAnswer(old.answer, isAnswered: old.isAnswered, for: record)
            }
        }
    }

    /// What Edit › Undo calls a change to an answer.
    static func answerActionName(wasAnswered: Bool, isAnswered: Bool) -> String {
        switch (wasAnswered, isAnswered) {
        case (false, true): "Answer Question"
        case (true, false): "Mark as Unanswered"
        default: "Edit Answer"
        }
    }
}
