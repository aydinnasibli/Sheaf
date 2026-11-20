import Foundation
import Observation
import SwiftData

/// Keeps the text index in step with the library, in the background: PDFs
/// are read as they're added, and the ones already there a little at a time
/// after Sheaf opens. Also runs the library's searches of PDF text.
///
/// PDFs in iCloud Drive that aren't on this Mac are left alone, since
/// reading one would download it: they're read once they're here (when
/// they're opened, or at a later check).
///
/// Nothing happens until `start(library:)`, which the app calls at launch
/// (not in unit tests, which make their own indexer).
@Observable
final class TextIndexer {
    static let shared = TextIndexer(
        index: TextIndex(directory: TextIndex.standardDirectory),
        recognizedTextFolder: RecognizedTextCache.defaultFolder
    )

    /// Goes up each time a PDF's text is added, so a search on screen runs again.
    private(set) var generation = 0

    @ObservationIgnored let index: TextIndex
    @ObservationIgnored private let cloud: any CloudFiles
    /// Where the reader keeps text read off scanned pages, or nil for none.
    @ObservationIgnored private let recognizedTextFolder: URL?
    /// How long to wait before looking again at PDFs that weren't on this Mac.
    @ObservationIgnored private let recheckInterval: Duration
    @ObservationIgnored private weak var library: LibraryStore?
    /// PDFs waiting to be read, newest additions first.
    @ObservationIgnored private var queue: [Source] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// PDFs in iCloud Drive that weren't on this Mac when their turn came.
    @ObservationIgnored private(set) var waitingForDownload: [UUID: Source] = [:]
    @ObservationIgnored private var recheck: Task<Void, Never>?

    /// What's needed to find a PDF's file away from the main thread.
    nonisolated struct Source: Sendable, Equatable {
        let id: UUID
        let bookmark: Data?
        let path: String
    }

    /// What happened when a PDF's turn came.
    nonisolated enum Outcome: Sendable, Equatable {
        /// New text was saved.
        case read
        /// The saved text is up to date.
        case unchanged
        /// The file is in iCloud Drive and isn't on this Mac, so it wasn't read.
        case notDownloaded
        /// The file can't be found, or isn't a PDF Sheaf can read.
        case unreadable
    }

    init(
        index: TextIndex, cloud: any CloudFiles = ICloudDrive(), recognizedTextFolder: URL? = nil,
        recheckInterval: Duration = .seconds(600)
    ) {
        self.index = index
        self.cloud = cloud
        self.recognizedTextFolder = recognizedTextFolder
        self.recheckInterval = recheckInterval
    }

    /// Starts indexing: PDFs added from now on right away, and the rest of
    /// the library after `delay`, so launching isn't slowed down. `nil`
    /// skips the catch-up (for tests).
    func start(library: LibraryStore, catchingUpAfter delay: Duration? = .seconds(5)) {
        self.library = library
        guard let delay else { return }
        Task {
            try? await Task.sleep(for: delay)
            await catchUp()
        }
    }

    /// Reads the text of PDFs just added, opened, or with new text read off
    /// their scanned pages, ahead of the rest. Ones that haven't changed
    /// are skipped quickly.
    func index(_ entries: [LibraryEntry]) {
        guard library != nil, !entries.isEmpty else { return }
        let sources = entries.map(source(for:))
        let ids = Set(sources.map(\.id))
        queue.removeAll { ids.contains($0.id) }
        queue.insert(contentsOf: sources, at: 0)
        runQueue()
    }

    /// Like `index(_:)`, for the PDF with this library ID, if it's still in
    /// the library (the reader calls it when it has read scanned pages).
    func index(entryID: UUID) {
        guard let entry = library?.entry(id: entryID) else { return }
        index([entry])
    }

    /// Queues every PDF in the library, most recently opened first. Those
    /// whose files haven't changed are skipped quickly. Also forgets the text
    /// of PDFs that were removed from the library.
    func catchUp() async {
        guard let library else { return }
        let descriptor = FetchDescriptor<LibraryEntry>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        let entries = (try? library.context.fetch(descriptor)) ?? []
        await index.removeAll(except: Set(entries.map(\.id)))
        let queued = Set(queue.map(\.id))
        queue += entries.filter { !queued.contains($0.id) }.map(source(for:))
        runQueue()
    }

    /// Looks again at the PDFs that weren't on this Mac: the ones that are
    /// now are read. Happens by itself every `recheckInterval`.
    func recheckWaiting() {
        recheck?.cancel()
        recheck = nil
        // Removed from the library meanwhile.
        if let library {
            waitingForDownload = waitingForDownload.filter { library.entry(id: $0.key) != nil }
        }
        let queued = Set(queue.map(\.id))
        queue += waitingForDownload.values.filter { !queued.contains($0.id) }
        runQueue()
    }

    /// Waits until every queued PDF has been read.
    func finishIndexing() async {
        while let worker {
            await worker.value
        }
    }

    /// The PDFs among `entries` whose text contains `query`, in the same order.
    func search(_ query: String, in entries: [LibraryEntry]) async -> [TextIndex.Match] {
        guard library != nil else { return [] }
        return await index.search(query, in: entries.map(\.id))
    }

    private func source(for entry: LibraryEntry) -> Source {
        Source(id: entry.id, bookmark: entry.bookmark, path: entry.lastKnownPath)
    }

    /// Reads queued PDFs one at a time, so indexing never takes over the Mac.
    private func runQueue() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task {
            while !queue.isEmpty {
                let source = queue.removeFirst()
                let (index, cloud, folder) = (index, cloud, recognizedTextFolder)
                let outcome = await Task.detached(priority: .utility) {
                    await Self.update(source, in: index, cloud: cloud, recognizedTextFolder: folder)
                }.value
                if outcome == .read { generation += 1 }
                waitingForDownload[source.id] = outcome == .notDownloaded ? source : nil
            }
            worker = nil
            scheduleRecheck()
        }
    }

    private func scheduleRecheck() {
        guard !waitingForDownload.isEmpty, recheck == nil else { return }
        let interval = recheckInterval
        recheck = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            self?.recheck = nil
            self?.recheckWaiting()
        }
    }

    /// Reads one PDF's text if the index doesn't have it yet, or the file has
    /// changed since; takes in text the reader has read off its scanned
    /// pages since. A file in iCloud Drive that isn't on this Mac is left
    /// alone: reading it would download it.
    nonisolated static func update(
        _ source: Source, in index: TextIndex, cloud: any CloudFiles = ICloudDrive(), recognizedTextFolder: URL? = nil
    ) async -> Outcome {
        guard let url = resolve(source) else { return .unreadable }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        // Before anything opens the file: that would start the download.
        guard cloud.status(of: url).isLocal else { return .notDownloaded }
        guard let stamp = TextIndex.Stamp(of: url) else { return .unreadable }
        let cache = recognizedTextFolder.flatMap { RecognizedTextCache(fileURL: url, libraryID: source.id, folder: $0) }
        let recognizedTextDate = cache?.savedAt

        switch await index.freshness(of: source.id, stamp: stamp, recognizedTextDate: recognizedTextDate) {
        case .current:
            return .unchanged
        case .needsRecognizedText(let pageCount, let scanned):
            // The PDF is the same: only the new words from its scanned pages go in.
            guard let cache, let recognizedTextDate else { return .unchanged }
            await index.addRecognizedText(cache.load(pageCount: pageCount, current: scanned), for: source.id, date: recognizedTextDate)
            return .read
        case .stale:
            guard let contents = TextIndex.read(url, libraryID: source.id, recognizedTextFolder: recognizedTextFolder) else {
                return .unreadable
            }
            await index.store(contents, for: source.id, stamp: stamp, recognizedTextDate: recognizedTextDate)
            return .read
        }
    }

    /// Finds the file through the library's security-scoped bookmark, like
    /// `LibraryStore.resolveFile(for:)`, but only for this one read: access
    /// isn't kept, the library isn't changed, and network drives aren't mounted.
    nonisolated static func resolve(_ source: Source) -> URL? {
        guard let bookmark = source.bookmark else {
            return FileManager.default.fileExists(atPath: source.path) ? URL(filePath: source.path) : nil
        }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
