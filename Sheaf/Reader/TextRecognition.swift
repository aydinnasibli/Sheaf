import CoreGraphics
import Foundation
import Vision

/// Text read off a scanned page, line by line, with where each word is.
nonisolated struct RecognizedPage: Codable, Sendable, Equatable {
    let index: Int
    /// The page's fingerprint when it was read (see `PageText.fingerprint`).
    let fingerprint: String
    let lines: [RecognizedLine]

    /// Every place `query` appears on the page: the line it's in, and the
    /// rectangle around the matching words, in page coordinates.
    func matches(of query: String) -> [(line: String, rect: CGRect)] {
        guard !query.isEmpty else { return [] }
        var found: [(line: String, rect: CGRect)] = []
        for line in lines {
            let text = line.text as NSString
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let match = text.range(of: query, options: [.caseInsensitive], range: searchRange)
                guard match.location != NSNotFound else { break }
                found.append((line: line.text, rect: line.rect(for: match)))
                let next = match.location + max(match.length, 1)
                searchRange = NSRange(location: next, length: text.length - next)
            }
        }
        return found
    }
}

nonisolated struct RecognizedLine: Codable, Sendable, Equatable {
    let text: String
    /// Around the whole line, in page coordinates.
    let rect: CGRect
    let words: [RecognizedWord]

    /// Around the words that overlap part of the line's text (UTF-16 offsets).
    func rect(for range: NSRange) -> CGRect {
        let touched = words.filter { $0.start < range.location + range.length && $0.end > range.location }
        guard let first = touched.first else { return rect }
        return touched.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }
}

nonisolated struct RecognizedWord: Codable, Sendable, Equatable {
    /// Where the word is in its line's text, in UTF-16 offsets.
    let start: Int
    let end: Int
    let rect: CGRect
}

/// Reads text in pictures of pages with Vision, on the Mac itself (the
/// same engine as Live Text). Nothing leaves the computer.
nonisolated enum TextRecognizer {
    /// The lines of text in `page`, top to bottom. Takes a fraction of a
    /// second for a full page, so it runs away from the main thread, and
    /// stops early if the task is cancelled (the PDF was closed).
    @concurrent
    static func lines(in page: PageImage) async -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Course readers and papers aren't always in English.
        request.automaticallyDetectsLanguage = true
        nonisolated(unsafe) let cancellable = request
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return [] }
            let handler = VNImageRequestHandler(cgImage: page.image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { line(from: $0, in: page) }
        } onCancel: {
            cancellable.cancel()
        }
    }

    private static func line(from observation: VNRecognizedTextObservation, in page: PageImage) -> RecognizedLine? {
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var words: [RecognizedWord] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { _, range, _, _ in
            guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
            let offsets = NSRange(range, in: text)
            words.append(RecognizedWord(
                start: offsets.location,
                end: offsets.location + offsets.length,
                rect: page.pageRect(forNormalized: box)
            ))
        }
        return RecognizedLine(text: text, rect: page.pageRect(forNormalized: observation.boundingBox), words: words)
    }
}
