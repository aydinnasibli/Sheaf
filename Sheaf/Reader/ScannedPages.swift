import Foundation
import Observation
import PDFKit

/// The pages of a PDF that are scanned images, and the text Sheaf reads off
/// them in the background so search can find words there too.
@Observable
final class ScannedPages {
    struct Progress: Equatable {
        var done: Int
        var total: Int
    }

    /// Text read so far, by page index.
    private(set) var recognized: [Int: RecognizedPage] = [:]
    /// Scanned pages read so far and in all, while reading in the background.
    private(set) var progress: Progress?

    /// Called after each page is read.
    @ObservationIgnored var onPageRead: ((RecognizedPage) -> Void)?
    /// Called once reading is done and the text is saved (also when it
    /// stopped early because the PDF was closed), so the library's search
    /// can take the text in.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Whether each page of the PDF on screen has selectable text, as found out.
    @ObservationIgnored private var hasText: [Int: Bool] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    /// Whether the page has text to select. Asked on the main thread for the
    /// page under the pointer, so each answer is kept.
    func pageHasText(_ page: PDFPage, at index: Int) -> Bool {
        if let known = hasText[index] { return known }
        let answer = PageText.hasSelectableText(page)
        hasText[index] = answer
        return answer
    }

    /// Starts reading the scanned pages, once. Text read before comes from
    /// `cacheFolder` (nil keeps nothing on disk), filed under the library
    /// entry's ID. Waits `delay` first, so opening the PDF stays quick.
    func startReading(
        using renderer: PageRenderer, pageCount: Int, fileURL: URL?, libraryID: UUID?,
        cacheFolder: URL?, after delay: Duration = .seconds(1)
    ) {
        guard task == nil else { return }
        let cache = fileURL.flatMap { url in
            cacheFolder.flatMap { RecognizedTextCache(fileURL: url, libraryID: libraryID, folder: $0) }
        }
        task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }

            // Find the scanned pages, a few at a time.
            var scanned: [ScannedPageInfo] = []
            for start in stride(from: 0, to: pageCount, by: 16) {
                guard !Task.isCancelled,
                      let found = await renderer.pagesWithoutText(in: start..<min(start + 16, pageCount))
                else { return }
                scanned += found
            }
            guard !scanned.isEmpty else { return }

            var read = cache?.load(pageCount: pageCount, current: scanned) ?? []
            await self?.add(read, total: scanned.count)
            let done = Set(read.map(\.index))
            var unsaved = 0
            for info in scanned where !done.contains(info.index) {
                guard !Task.isCancelled else { break }
                guard let image = await renderer.imageForReading(page: info.index) else { continue }
                let lines = await TextRecognizer.lines(in: image)
                guard !Task.isCancelled else { break }
                let page = RecognizedPage(index: info.index, fingerprint: info.fingerprint, lines: lines)
                read.append(page)
                await self?.add([page], total: scanned.count)
                unsaved += 1
                // Save as it goes, so closing the PDF halfway keeps what's done.
                if unsaved >= 5 {
                    cache?.save(read, pageCount: pageCount)
                    unsaved = 0
                }
            }
            if unsaved > 0 { cache?.save(read, pageCount: pageCount) }
            await self?.finish()
        }
    }

    /// Stops reading (the PDF was closed). What's read so far is saved.
    func cancel() {
        task?.cancel()
        progress = nil
    }

    private func add(_ pages: [RecognizedPage], total: Int) {
        for page in pages {
            recognized[page.index] = page
            hasText[page.index] = false
        }
        // Cleared by `finish`, once the text is saved too.
        progress = Progress(done: min(recognized.count, total), total: total)
        for page in pages { onPageRead?(page) }
    }

    private func finish() {
        progress = nil
        onFinished?()
    }
}
