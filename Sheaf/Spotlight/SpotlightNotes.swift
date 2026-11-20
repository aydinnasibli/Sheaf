import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// What Spotlight gets for a page note or a PDF's summary: a copy of its
/// data, so the Spotlight item can be made off the main thread. Picking
/// one opens the PDF, at the note's page.
nonisolated struct SpotlightNote: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case pageNote(id: UUID, pageIndex: Int, pageLabel: String)
        case summary
    }

    let kind: Kind
    let pdfID: UUID
    let pdfTitle: String
    let text: String
    let modifiedAt: Date?

    /// Spotlight's name for it: "note-<id>" or "summary-<PDF's id>".
    var identifier: String {
        switch kind {
        case .pageNote(let id, _, _): "note-\(id.uuidString)"
        case .summary: "summary-\(pdfID.uuidString)"
        }
    }

    /// A page note shows its first line, then the rest and where it is; a
    /// summary shows "My summary of “Title”", then the summary. Grouped by
    /// PDF, like highlights, so removing a PDF removes these too.
    func searchableItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        switch kind {
        case .pageNote(_, _, let pageLabel):
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            attributes.title = firstLine
            attributes.contentDescription = "\(text)\nNote on page \(pageLabel) of \u{201C}\(pdfTitle)\u{201D}"
            attributes.keywords = ["Note"]
        case .summary:
            attributes.title = "My summary of \u{201C}\(pdfTitle)\u{201D}"
            attributes.contentDescription = text
            attributes.keywords = ["Summary"]
        }
        attributes.textContent = text
        attributes.contentModificationDate = modifiedAt
        let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: pdfID.uuidString, attributeSet: attributes)
        // Spotlight forgets items after a month unless told otherwise.
        item.expirationDate = .distantFuture
        return item
    }
}

extension SpotlightNote {
    /// `nil` for an empty note, or one no longer in a PDF.
    init?(_ note: PageNote) {
        guard let entry = note.entry, !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(
            kind: .pageNote(id: note.id, pageIndex: note.pageIndex, pageLabel: note.displayPage),
            pdfID: entry.id, pdfTitle: entry.title, text: note.text, modifiedAt: note.modifiedAt
        )
    }

    /// `nil` if the PDF has no summary.
    init?(summaryOf entry: LibraryEntry) {
        guard !entry.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(kind: .summary, pdfID: entry.id, pdfTitle: entry.title, text: entry.summary, modifiedAt: nil)
    }

    /// What a Spotlight result names, from its identifier.
    enum Target: Equatable {
        case highlight(UUID)
        case pageNote(UUID)
        case summary(pdfID: UUID)

        init?(identifier: String) {
            if let id = UUID(uuidString: identifier) {
                self = .highlight(id)
            } else if identifier.hasPrefix("note-"), let id = UUID(uuidString: String(identifier.dropFirst(5))) {
                self = .pageNote(id)
            } else if identifier.hasPrefix("summary-"), let id = UUID(uuidString: String(identifier.dropFirst(8))) {
                self = .summary(pdfID: id)
            } else {
                return nil
            }
        }
    }
}

/// Keeps Spotlight's copy of page notes and summaries current by watching
/// the library's saves, so every way one changes (typing, Undo, removing
/// or renaming a PDF) reaches Spotlight without each of them having to say so.
final class SpotlightNotesWatcher {
    private let context: ModelContext
    private weak var index: (any HighlightIndexing)?
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    /// Page notes Spotlight has, so deleting one can take it out.
    private var notes: [PersistentIdentifier: UUID] = [:]
    /// Each PDF's title and summary as Spotlight has them, so a PDF that's
    /// only been read further isn't sent again.
    private var pdfs: [PersistentIdentifier: (id: UUID, title: String, summary: String)] = [:]

    init(context: ModelContext, index: any HighlightIndexing) {
        self.context = context
        self.index = index
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Every page note and summary in the library, for rebuilding the index.
    /// Also starts following changes, if it hasn't yet.
    func allNotes() -> [SpotlightNote] {
        startWatching()
        let pageNotes = (try? context.fetch(FetchDescriptor<PageNote>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<LibraryEntry>())) ?? []
        for note in pageNotes { notes[note.persistentModelID] = note.id }
        for entry in entries { pdfs[entry.persistentModelID] = (entry.id, entry.title, entry.summary) }
        return pageNotes.compactMap(SpotlightNote.init) + entries.compactMap(SpotlightNote.init(summaryOf:))
    }

    func startWatching() {
        guard observer == nil else { return }
        // SwiftData may tell of a save from another thread, a moment later.
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: .main) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            let changed = [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers]
                .flatMap { info[$0.rawValue] as? [PersistentIdentifier] ?? [] }
            let deleted = info[ModelContext.NotificationKey.deletedIdentifiers.rawValue] as? [PersistentIdentifier] ?? []
            MainActor.assumeIsolated { self?.didSave(changed: changed, deleted: deleted) }
        }
    }

    private func didSave(changed: [PersistentIdentifier], deleted: [PersistentIdentifier]) {
        guard let index else { return }
        var indexed: [SpotlightNote] = []
        var removed: [String] = []
        func add(_ note: PageNote) {
            notes[note.persistentModelID] = note.id
            if let item = SpotlightNote(note) { indexed.append(item) } else { removed.append("note-\(note.id.uuidString)") }
        }
        for identifier in changed {
            let model = context.model(for: identifier)
            // Deleted since (it's in a later save's deletions).
            guard model.modelContext != nil, !model.isDeleted else { continue }
            if let note = model as? PageNote {
                add(note)
            } else if let entry = model as? LibraryEntry {
                let known = pdfs[identifier]
                pdfs[identifier] = (entry.id, entry.title, entry.summary)
                guard known?.title != entry.title || known?.summary != entry.summary else { continue }
                if let summary = SpotlightNote(summaryOf: entry) {
                    indexed.append(summary)
                } else if known?.summary.isEmpty == false {
                    removed.append("summary-\(entry.id.uuidString)")
                }
                // Each note's result says which PDF it's in.
                if known != nil, known?.title != entry.title { entry.pageNotes.forEach(add) }
            }
        }
        for identifier in deleted {
            if let id = notes.removeValue(forKey: identifier) { removed.append("note-\(id.uuidString)") }
            if let pdf = pdfs.removeValue(forKey: identifier) { removed.append("summary-\(pdf.id.uuidString)") }
        }
        var seen = Set<String>()
        indexed = indexed.reversed().filter { seen.insert($0.identifier).inserted }.reversed()
        if !removed.isEmpty { index.remove(noteIdentifiers: removed) }
        if !indexed.isEmpty { index.index(notes: indexed) }
    }
}
