import AppKit
import CoreSpotlight
import SwiftData
import UniformTypeIdentifiers

/// Where highlights are indexed for searching outside Sheaf: Spotlight in
/// the app, a fake in the tests. `LibraryStore` calls it whenever a highlight
/// or PDF changes.
protocol HighlightIndexing: AnyObject {
    /// Adds highlights, or updates ones already indexed.
    func index(_ highlights: [SpotlightHighlight])
    func remove(highlightIDs: [UUID])
    /// Removes every highlight of these PDFs.
    func remove(pdfIDs: [UUID])
    /// Starts over with exactly these highlights.
    func replaceAll(with highlights: [SpotlightHighlight])
    /// Adds page notes and summaries, or updates ones already indexed.
    func index(notes: [SpotlightNote])
    /// Removes page notes and summaries (see `SpotlightNote.identifier`).
    func remove(noteIdentifiers: [String])
}

extension HighlightIndexing {
    func index(notes: [SpotlightNote]) {}
    func remove(noteIdentifiers: [String]) {}

    /// Adds a highlight that was just made or changed.
    func index(_ record: HighlightRecord) {
        if let highlight = SpotlightHighlight(record) { index([highlight]) }
    }
}

/// What Spotlight gets for one highlight: a copy of its data, so the
/// Spotlight item can be made off the main thread.
nonisolated struct SpotlightHighlight: Sendable, Equatable {
    let id: UUID
    let pdfID: UUID
    let pdfTitle: String
    let pageIndex: Int
    /// The page as printed in the PDF ("xii", "245"), else its number.
    let pageLabel: String
    let kindName: String
    let text: String
    let note: String
    let createdAt: Date
    /// An answered Question's answer ("" when she wrote none); `nil` for
    /// open questions and other colors.
    var answer: String?

    /// The Spotlight result: the highlighted text as the title, then the
    /// note, the answer and where it is. Grouped by PDF, so removing a PDF
    /// removes its highlights in one go.
    func searchableItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = text
        attributes.contentDescription = summary
        attributes.keywords = [kindName]
        attributes.contentCreationDate = createdAt
        let item = CSSearchableItem(
            uniqueIdentifier: id.uuidString, domainIdentifier: pdfID.uuidString, attributeSet: attributes
        )
        // Spotlight forgets items after a month unless told otherwise.
        item.expirationDate = .distantFuture
        return item
    }

    /// The note, if there is one, then the answer of an answered question,
    /// then "Question on page 4 of “Title”".
    var summary: String {
        var lines = note.isEmpty ? [] : [note]
        if let answer {
            lines.append(answer.isEmpty ? "Answered" : "Answer: \(answer)")
        }
        lines.append("\(kindName) on page \(pageLabel) of \u{201C}\(pdfTitle)\u{201D}")
        return lines.joined(separator: "\n")
    }
}

extension SpotlightHighlight {
    /// `nil` for a highlight that's no longer in a PDF.
    init?(_ record: HighlightRecord) {
        guard let entry = record.entry else { return nil }
        self.init(
            id: record.id,
            pdfID: entry.id,
            pdfTitle: entry.title,
            pageIndex: record.pageIndex,
            pageLabel: record.displayPage,
            kindName: record.kind.name,
            text: record.text,
            note: record.note,
            createdAt: record.createdAt,
            answer: record.isAnsweredQuestion ? record.answer : nil
        )
    }
}

/// Keeps Spotlight's copy of the highlights current. Changes go to Spotlight
/// one after another in the background, in the order they were made, so a
/// highlight deleted right after it was added doesn't come back.
final class SpotlightIndex: HighlightIndexing {
    private var queue: Task<Void, Never>?
    /// Follows page notes and summaries.
    private var notesWatcher: SpotlightNotesWatcher?

    /// Indexes the library's highlights, page notes and summaries once, a
    /// few seconds after launch, and from then on follows every change.
    /// Starting over each launch also catches anything changed while Sheaf
    /// wasn't keeping the index, such as a PDF renamed or highlights made by
    /// an older version.
    static func start(for library: LibraryStore) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        let index = SpotlightIndex()
        library.searchIndex = index
        let watcher = SpotlightNotesWatcher(context: library.context, index: index)
        index.notesWatcher = watcher
        // From now on, so nothing changed meanwhile is missed.
        watcher.startWatching()
        Task {
            try? await Task.sleep(for: .seconds(3))
            index.replaceAll(with: library.spotlightHighlights())
            index.index(notes: watcher.allNotes())
        }
    }

    func index(notes: [SpotlightNote]) {
        guard !notes.isEmpty else { return }
        enqueue {
            try await CSSearchableIndex.default().indexSearchableItems(notes.map { $0.searchableItem() })
        }
    }

    func remove(noteIdentifiers: [String]) {
        guard !noteIdentifiers.isEmpty else { return }
        enqueue {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: noteIdentifiers)
        }
    }

    func index(_ highlights: [SpotlightHighlight]) {
        guard !highlights.isEmpty else { return }
        enqueue {
            try await CSSearchableIndex.default().indexSearchableItems(highlights.map { $0.searchableItem() })
        }
    }

    func remove(highlightIDs: [UUID]) {
        guard !highlightIDs.isEmpty else { return }
        enqueue {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: highlightIDs.map(\.uuidString))
        }
    }

    func remove(pdfIDs: [UUID]) {
        guard !pdfIDs.isEmpty else { return }
        enqueue {
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: pdfIDs.map(\.uuidString))
        }
    }

    func replaceAll(with highlights: [SpotlightHighlight]) {
        enqueue {
            let index = CSSearchableIndex.default()
            try await index.deleteAllSearchableItems()
            // A few hundred at a time, so a big library doesn't arrive in one lump.
            for start in stride(from: 0, to: highlights.count, by: 500) {
                let batch = highlights[start..<min(start + 500, highlights.count)]
                try await index.indexSearchableItems(batch.map { $0.searchableItem() })
            }
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async throws -> Void) {
        let previous = queue
        queue = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try await work()
            } catch {
                NSLog("Sheaf: couldn\u{2019}t update Spotlight (\(error))")
            }
        }
    }
}

extension LibraryStore {
    /// Every highlight that's in a PDF, for rebuilding the Spotlight index.
    func spotlightHighlights() -> [SpotlightHighlight] {
        let records = (try? context.fetch(FetchDescriptor<HighlightRecord>())) ?? []
        return records.compactMap(SpotlightHighlight.init)
    }

    /// The highlight a Spotlight result stands for.
    fileprivate func spotlightRecord(id: UUID) -> HighlightRecord? {
        let descriptor = FetchDescriptor<HighlightRecord>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// The page note a Spotlight result stands for.
    fileprivate func spotlightPageNote(id: UUID) -> PageNote? {
        let descriptor = FetchDescriptor<PageNote>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}

/// Opens a Spotlight result: the PDF, scrolled to the highlight or at the
/// note's page; a summary opens its PDF.
enum SpotlightResult {
    /// The activity handled last. One result can arrive twice, through the
    /// app delegate and through SwiftUI, and should only open once.
    private static weak var lastActivity: NSUserActivity?

    /// Returns false if the activity isn't a Spotlight result from Sheaf.
    @discardableResult
    static func open(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let target = SpotlightNote.Target(identifier: identifier)
        else { return false }
        guard activity !== lastActivity else { return true }
        lastActivity = activity

        let router = WindowRouter.shared
        let library = router.library
        switch target {
        case .highlight(let id):
            if let record = library?.spotlightRecord(id: id), let entry = record.entry {
                router.open(entry, at: record)
                return true
            }
            library?.searchIndex?.remove(highlightIDs: [id])
        case .pageNote(let id):
            if let note = library?.spotlightPageNote(id: id), let entry = note.entry {
                router.open(entry, atPage: note.pageIndex)
                return true
            }
            library?.searchIndex?.remove(noteIdentifiers: [identifier])
        case .summary(let pdfID):
            if let entry = library?.entry(id: pdfID) {
                router.open(entry)
                return true
            }
            library?.searchIndex?.remove(noteIdentifiers: [identifier])
        }
        // Deleted since Spotlight last heard about it.
        router.showLibrary()
        return true
    }
}
