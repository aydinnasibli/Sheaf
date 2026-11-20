import Foundation
import Observation
import SwiftData

/// Keeps the text index in step with the library, in the background: PDFs
/// are read as they're added, and the ones already there a little at a time
/// after Sheaf opens. Also runs the library's searches of PDF text.
///
/// Nothing happens until `start(library:)`, which the app calls at launch
/// (not in unit tests, which make their own indexer).
@Observable
final class TextIndexer {
    static let shared = TextIndexer(index: TextIndex(directory: TextIndex.standardDirectory))

    /// Goes up each time a PDF's text is added, so a search on screen runs again.
    private(set) var generation = 0

    @ObservationIgnored let index: TextIndex
    @ObservationIgnored private weak var library: LibraryStore?
    /// PDFs waiting to be read, newest additions first.
    @ObservationIgnored private var queue: [Source] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// What's needed to find a PDF's file away from the main thread.
    nonisolated struct Source: Sendable, Equatable {
        let id: UUID
        let bookmark: Data?
        let path: String
    }

    init(index: TextIndex) {
        self.index = index
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

    /// Reads the text of PDFs just added, ahead of the rest.
    func index(_ entries: [LibraryEntry]) {
        guard library != nil, !entries.isEmpty else { return }
        let sources = entries.map(source(for:))
        let ids = Set(sources.map(\.id))
        queue.removeAll { ids.contains($0.id) }
        queue.insert(contentsOf: sources, at: 0)
        runQueue()
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
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                let source = queue.removeFirst()
                let index = index
                let didRead = await Task.detached(priority: .utility) {
                    await Self.update(source, in: index)
                }.value
                if didRead { generation += 1 }
            }
            worker = nil
        }
    }

    /// Reads one PDF's text if the index doesn't have it yet, or the file has
    /// changed since. Returns whether new text was saved.
    nonisolated static func update(_ source: Source, in index: TextIndex) async -> Bool {
        guard let url = resolve(source) else { return false }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let stamp = TextIndex.Stamp(of: url) else { return false }
        if await index.isCurrent(source.id, stamp: stamp) { return false }
        guard let pages = TextIndex.readText(of: url) else { return false }
        await index.store(pages, for: source.id, stamp: stamp)
        return true
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
