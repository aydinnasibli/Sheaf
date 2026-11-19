import AppKit
import AVFoundation
import Observation
import PDFKit

/// What the Edit menu does with the text selected in a PDF: Find > Use
/// Selection for Find, and Speech.
extension ReaderModel {
    /// The selected text on one line, or `nil` when nothing is selected.
    var selectedTextForFind: String? {
        guard let text = pdfView.currentSelection?.string else { return nil }
        // A selection across lines carries line breaks; a search is one line.
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// Edit > Find > Use Selection for Find (⌘E): searches this PDF for the
    /// selected text. As in other Mac apps, the text also goes on the shared
    /// Find pasteboard, so Find Next in another app looks for it too.
    /// Returns false when nothing is selected.
    @discardableResult
    func useSelectionForFind(pasteboard: NSPasteboard = NSPasteboard(name: .find)) -> Bool {
        guard let text = selectedTextForFind else { return false }
        searchQuery = text
        isSearchBarVisible = true
        searchFocusRequest += 1
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    /// What Edit > Speech > Start Speaking reads: the selected text, or else
    /// the page on screen (both pages in the two-page layouts). `nil` when
    /// there's no text, as on a scanned page.
    var textToSpeak: String? {
        if let selected = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            return selected
        }
        let pages = visiblePageIndices
            .compactMap { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }
}

/// Reads text aloud for Edit > Speech, with the voice and speed chosen in
/// System Settings > Accessibility > Spoken Content.
@Observable
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// True while reading, so Stop Speaking is only on when there's
    /// something to stop.
    private(set) var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// The text being read. Stopping it and starting new text both report
    /// back later, so only news about this one changes `isSpeaking`.
    @ObservationIgnored private var current: ObjectIdentifier?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        current = ObjectIdentifier(utterance)
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func ended(_ utterance: ObjectIdentifier) {
        guard utterance == current else { return }
        current = nil
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(id) }
    }
}
