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

    /// A download from iCloud Drive that's under way.
    struct Download: Equatable {
        let startedAt: Date
        /// Whether iCloud is sending the file. It isn't while the Mac is
        /// offline, or before iCloud gets to it.
        var isTransferring = false
        /// What iCloud said went wrong, if it did. Sheaf keeps asking.
        var problem: String?
    }

    let id: UUID
    private(set) var phase = Phase.loading
    /// Set while `phase` is `.downloading`.
    private(set) var download: Download?
    /// A highlight to scroll to once the reader is on screen.
    var pendingHighlightID: UUID?
    /// A page (0-based) to go to once the reader is on screen.
    var pendingPageIndex: Int?

    @ObservationIgnored let entry: LibraryEntry
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let cloud: any CloudFiles
    /// How often to ask iCloud whether the file has arrived.
    @ObservationIgnored private let downloadCheckInterval: Duration
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    /// The title when the PDF was opened, for after it's removed from the library.
    @ObservationIgnored private let openedTitle: String

    /// Doesn't load the file yet: `loadIfNeeded()` does, the first time the
    /// PDF is shown, so reopening many PDFs at launch stays quick.
    init(
        entry: LibraryEntry, library: LibraryStore, cloud: any CloudFiles = ICloudDrive(),
        downloadCheckInterval: Duration = .seconds(1)
    ) {
        self.id = entry.id
        self.openedTitle = entry.title
        self.entry = entry
        self.library = library
        self.cloud = cloud
        self.downloadCheckInterval = downloadCheckInterval
    }

    /// The PDF's title in the library. Read from the entry each time, so
    /// renaming the PDF shows everywhere it's open (the entry is observable).
    var title: String {
        entry.isInLibrary ? entry.title : openedTitle
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
        let didDownload = cloud.status(of: url) != .local
        guard await downloadIfNeeded(url) else { return }

        let loaded = await Self.read(url, excluding: library.knownHighlightIDs(of: entry), drawingCover: entry.cover == nil)
        guard !isClosed else { return }
        guard let loaded else {
            phase = .failed(
                title: "Can\u{2019}t Open This PDF",
                message: "\u{201C}\(entry.title)\u{201D} may be damaged or may not be a PDF."
            )
            return
        }
        let document = loaded.document
        phase = document.isLocked
            ? .locked(document, url)
            : .ready(makeModel(document: document, url: url, found: loaded.found, scan: loaded.scan, cover: loaded.cover))
        // Now that it's on this Mac, the library's search can read it too.
        if didDownload { TextIndexer.shared.index([entry]) }
    }

    private func makeModel(
        document: PDFDocument, url: URL, found: [PDFHighlightImport.Found], scan: OpeningScan? = nil, cover: Data? = nil
    ) -> ReaderModel {
        library.recordOpen(of: url, document: document, cover: cover)
        // Highlights saved in the file that the library doesn't have (it was
        // removed from the library and opened again, say) join the library.
        library.importHighlights(found, into: entry)
        return ReaderModel(document: document, entry: entry, store: library, fileURL: url, scan: scan)
    }

    // MARK: Reading the file

    /// The PDF, the Sheaf highlights in it the library doesn't know, what
    /// the reader needs from its pages, and its cover if one was wanted.
    private nonisolated struct Loaded: @unchecked Sendable {
        // Made on a background thread, then only used on the main thread.
        let document: PDFDocument
        let found: [PDFHighlightImport.Found]
        let scan: OpeningScan?
        let cover: Data?
    }

    /// Reads and parses the file away from the main thread, so a big PDF or
    /// a slow drive doesn't freeze the window. The whole file is read into
    /// memory, so saving highlights into it later can't disturb the copy on
    /// screen. The pages are gone through here, once, for what the reader
    /// needs from them, so the main thread doesn't have to.
    private nonisolated static func read(_ url: URL, excluding known: Set<UUID>, drawingCover: Bool) async -> Loaded? {
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
            guard !document.isLocked else { return Loaded(document: document, found: [], scan: nil, cover: nil) }
            let scan = OpeningScan(document)
            // Read back only when the file has highlights the library doesn't know.
            let found = scan.highlightIDs.isSubset(of: known) ? [] : PDFHighlightImport.highlights(in: document, excluding: known)
            let cover = drawingCover ? LibraryStore.coverImage(for: document) : nil
            return Loaded(document: document, found: found, scan: scan, cover: cover)
        }.value
    }

    // MARK: iCloud Drive

    /// For a file in iCloud Drive that isn't on this Mac yet: starts the
    /// download and waits for it, showing "Downloading from iCloud…", for
    /// as long as it takes: a big PDF on a slow connection is still on its
    /// way. If iCloud reports a problem, it's shown, and Sheaf keeps asking.
    /// Cancel closes the PDF. Returns false if the PDF was closed.
    private func downloadIfNeeded(_ url: URL) async -> Bool {
        guard cloud.status(of: url) != .local else { return true }
        phase = .downloading
        download = Download(startedAt: .now)
        defer { download = nil }
        cloud.startDownloading(url)
        var lastAsked = ContinuousClock.now
        while true {
            switch cloud.status(of: url) {
            case .local:
                phase = .loading
                return true
            case .notDownloaded(let isDownloading):
                download?.isTransferring = isDownloading
                download?.problem = nil
            case .failed(let problem):
                download?.isTransferring = false
                download?.problem = problem
                // Asked again now and then: the problem may have passed (the Mac is back online).
                if ContinuousClock.now - lastAsked > .seconds(30) {
                    cloud.startDownloading(url)
                    lastAsked = .now
                }
            }
            do { try await Task.sleep(for: downloadCheckInterval) } catch { return false }
            guard !isClosed else { return false }
        }
    }
}
