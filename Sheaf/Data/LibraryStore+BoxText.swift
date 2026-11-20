import Foundation

extension LibraryStore {
    /// The words read off a box highlight's picture, in place of "Image
    /// area", once they're found. Spotlight hears about them too. The text
    /// isn't written into the PDF (the box is), so the file needn't be saved.
    func setRecognizedText(_ text: String, for record: HighlightRecord) {
        guard record.text != text else { return }
        record.text = text
        save()
        searchIndex?.index(record)
    }
}
