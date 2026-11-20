import AppKit
import Observation
import PDFKit
import SwiftUI

/// One open PDF: loads the file, asks for a password if needed, and keeps
/// its reader (page, zoom, search) while you switch to the library and back.
@Observable
final class OpenDocument: Identifiable {
    enum Phase {
        case loading
        /// The file is in iCloud Drive and is being downloaded to this Mac.
        case downloading
        case locked(PDFDocument, URL)
        case ready(ReaderModel)
        case failed(title: String, message: String)
    }

    let id: UUID
    private(set) var title: String
    private(set) var phase = Phase.loading
    /// A highlight to scroll to once the reader is on screen.
    var pendingHighlightID: UUID?
    /// A page (0-based) to go to once the reader is on screen.
    var pendingPageIndex: Int?

    @ObservationIgnored let entry: LibraryEntry
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    /// Doesn't load the file yet: `loadIfNeeded()` does, the first time the
    /// PDF is shown, so reopening many PDFs at launch stays quick.
    init(entry: LibraryEntry, library: LibraryStore) {
        self.id = entry.id
        self.title = entry.title
        self.entry = entry
        self.library = library
    }

    var model: ReaderModel? {
        if case .ready(let model) = phase { return model }
        return nil
    }

    var hasStartedLoading: Bool { loadTask != nil }

    func loadIfNeeded() {
        guard loadTask == nil else { return }
        loadTask = Task { await load() }
    }

    /// Waits until loading has finished (or stopped because the PDF was closed).
    func waitUntilLoaded() async {
        await loadTask?.value
    }

    /// Tries a password for a protected PDF. Returns false if it was wrong.
    func unlock(with password: String) -> Bool {
        guard case .locked(let document, let url) = phase, document.unlock(withPassword: password) else { return false }
        let found = PDFHighlightImport.highlights(in: document, excluding: library.knownHighlightIDs(of: entry))
        phase = .ready(makeModel(document: document, url: url, found: found))
        return true
    }

    func close() {
        isClosed = true
        loadTask?.cancel()
        model?.close()
    }

    private func load() async {
        // Closed before loading began: leave the file alone.
        guard !isClosed else { return }
        guard let url = library.resolveFile(for: entry) else {
            phase = .failed(
                title: "Can\u{2019}t Find \u{201C}\(entry.title)\u{201D}",
                message: "It was last at \(entry.lastKnownPath). It may have been deleted, or moved to a drive that isn\u{2019}t connected."
            )
            return
        }
        guard await downloadIfNeeded(url) else { return }

        let loaded = await Self.read(url, excluding: library.knownHighlightIDs(of: entry))
        guard !isClosed else { return }
        guard let loaded else {
            phase = .failed(
                title: "Can\u{2019}t Open This PDF",
                message: "\u{201C}\(entry.title)\u{201D} may be damaged or may not be a PDF."
            )
            return
        }
        let document = loaded.document
        phase = document.isLocked ? .locked(document, url) : .ready(makeModel(document: document, url: url, found: loaded.found))
    }

    private func makeModel(document: PDFDocument, url: URL, found: [PDFHighlightImport.Found]) -> ReaderModel {
        library.recordOpen(of: url, document: document)
        // Highlights saved in the file that the library doesn't have (it was
        // removed from the library and opened again, say) join the library.
        library.importHighlights(found, into: entry)
        title = entry.title
        return ReaderModel(document: document, entry: entry, store: library, fileURL: url)
    }

    // MARK: Reading the file

    /// The PDF, and the Sheaf highlights in it the library doesn't know.
    private nonisolated struct Loaded: @unchecked Sendable {
        // Made on a background thread, then only used on the main thread.
        let document: PDFDocument
        let found: [PDFHighlightImport.Found]
    }

    /// Reads and parses the file away from the main thread, so a big PDF or
    /// a slow drive doesn't freeze the window. The whole file is read into
    /// memory, so saving highlights into it later can't disturb the copy on
    /// screen.
    private nonisolated static func read(_ url: URL, excluding known: Set<UUID>) async -> Loaded? {
        await Task.detached(priority: .userInitiated) {
            var data: Data?
            var coordinationError: NSError?
            // Coordinated, so it never reads a file another app (or a save
            // of Sheaf's) is halfway through writing.
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
                data = try? Data(contentsOf: target)
            }
            if data == nil, coordinationError != nil {
                data = try? Data(contentsOf: url)
            }
            guard let data, let document = PDFDocument(data: data) else { return nil }
            let found = document.isLocked ? [] : PDFHighlightImport.highlights(in: document, excluding: known)
            return Loaded(document: document, found: found)
        }.value
    }

    // MARK: iCloud Drive

    /// For a file in iCloud Drive that isn't on this Mac yet: starts the
    /// download and waits for it, showing "Downloading from iCloud…".
    /// Returns false if the download failed or the PDF was closed.
    private func downloadIfNeeded(_ url: URL) async -> Bool {
        guard Self.cloudStatus(of: url).needsDownload else { return true }
        phase = .downloading
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        while true {
            let status = Self.cloudStatus(of: url)
            if !status.needsDownload { break }
            if let error = status.error {
                phase = .failed(
                    title: "Can\u{2019}t Download \u{201C}\(entry.title)\u{201D}",
                    message: "It\u{2019}s in iCloud Drive and couldn\u{2019}t be downloaded to this Mac. \(error.localizedDescription)"
                )
                return false
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return false }
        }
        phase = .loading
        return true
    }

    private nonisolated static func cloudStatus(of url: URL) -> (needsDownload: Bool, error: Error?) {
        var url = url
        // Resource values are cached per URL; the status changes as it downloads.
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemDownloadingErrorKey,
        ])
        guard values?.isUbiquitousItem == true else { return (false, nil) }
        return (values?.ubiquitousItemDownloadingStatus == .notDownloaded, values?.ubiquitousItemDownloadingError)
    }
}
