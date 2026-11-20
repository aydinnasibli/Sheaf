import Foundation
import SwiftData

/// Everything the library knows about a PDF, copied just before it's
/// removed, so Undo can put it back exactly as it was: the same IDs, its
/// highlights (with their notes, answers and page labels), page notes,
/// summary, bookmarks, collection, star, progress and dates.
nonisolated struct RemovedPDF: Sendable {
    let id: UUID
    let title: String
    let lastKnownPath: String
    let bookmark: Data?
    let pageCount: Int
    let lastPageIndex: Int
    let furthestPageIndex: Int
    let readPages: [Int]
    let addedAt: Date
    let lastOpenedAt: Date
    let isStarred: Bool
    let bookmarkedPages: [Int]
    let needsFileSave: Bool
    let removedHighlightIDs: [UUID]
    let summary: String
    let pageLabels: [String]
    let cover: Data?
    /// The collection it was in. If that collection is deleted before Undo,
    /// the PDF comes back without one.
    let collectionID: UUID?
    let highlights: [HighlightSnapshot]
    let pageNotes: [PageNoteSnapshot]
}

extension RemovedPDF {
    init(_ entry: LibraryEntry) {
        self.init(
            id: entry.id,
            title: entry.title,
            lastKnownPath: entry.lastKnownPath,
            bookmark: entry.bookmark,
            pageCount: entry.pageCount,
            lastPageIndex: entry.lastPageIndex,
            furthestPageIndex: entry.furthestPageIndex,
            readPages: entry.readPages,
            addedAt: entry.addedAt,
            lastOpenedAt: entry.lastOpenedAt,
            isStarred: entry.isStarred,
            bookmarkedPages: entry.bookmarkedPages,
            needsFileSave: entry.needsFileSave,
            removedHighlightIDs: entry.removedHighlightIDs,
            summary: entry.summary,
            pageLabels: entry.pageLabels,
            cover: entry.cover,
            collectionID: entry.collection?.id,
            highlights: entry.highlights.map(HighlightSnapshot.init),
            pageNotes: entry.pageNotes.map(PageNoteSnapshot.init)
        )
    }
}

/// Removing PDFs from the library (and Undo), and renaming them.
extension LibraryStore {
    /// Removes PDFs from the library: their highlights, notes and bookmarks
    /// in Sheaf go too. The files themselves are left alone, with whatever
    /// highlights were saved into them. Returns what Undo needs to bring
    /// them back (see `restore(_:)`).
    @discardableResult
    func remove(_ items: [LibraryEntry]) -> [RemovedPDF] {
        let removed = items.map(RemovedPDF.init)
        for item in items { context.delete(item) }
        save()
        searchIndex?.remove(pdfIDs: removed.map(\.id))
        return removed
    }

    /// Puts removed PDFs back, as they were. A PDF whose file was added to
    /// the library again meanwhile is left as it is now: opening it already
    /// brought back the highlights saved in the file. Returns the PDFs put back.
    @discardableResult
    func restore(_ removed: [RemovedPDF]) -> [LibraryEntry] {
        var restored: [LibraryEntry] = []
        var highlights: [HighlightRecord] = []
        for pdf in removed {
            guard entry(id: pdf.id) == nil, !hasEntry(atPath: pdf.lastKnownPath) else { continue }
            let entry = LibraryEntry(title: pdf.title, path: pdf.lastKnownPath, pageCount: pdf.pageCount, now: pdf.addedAt)
            entry.id = pdf.id
            entry.bookmark = pdf.bookmark
            entry.lastPageIndex = pdf.lastPageIndex
            entry.furthestPageIndex = pdf.furthestPageIndex
            entry.readPages = pdf.readPages
            entry.lastOpenedAt = pdf.lastOpenedAt
            entry.isStarred = pdf.isStarred
            entry.bookmarkedPages = pdf.bookmarkedPages
            entry.needsFileSave = pdf.needsFileSave
            entry.removedHighlightIDs = pdf.removedHighlightIDs
            entry.summary = pdf.summary
            entry.pageLabels = pdf.pageLabels
            entry.cover = pdf.cover
            context.insert(entry)
            entry.collection = pdf.collectionID.flatMap(collection(id:))
            var taken = takenHighlightIDs(besides: entry)
            for snapshot in pdf.highlights {
                let record = HighlightRecord(
                    pageIndex: snapshot.pageIndex,
                    kind: HighlightKind(rawValue: snapshot.kindRaw) ?? .keyIdea,
                    text: snapshot.text,
                    rects: snapshot.rects,
                    now: snapshot.createdAt
                )
                // Another PDF has a highlight with this ID meanwhile (a copy
                // of this file was opened, say): this one gets a new ID.
                record.id = uniqueHighlightID(snapshot.id, comingInto: entry, taken: &taken)
                record.note = snapshot.note
                record.pageLabel = snapshot.pageLabel
                record.isAnswered = snapshot.isAnswered
                record.answer = snapshot.answer
                context.insert(record)
                record.entry = entry
                highlights.append(record)
            }
            for snapshot in pdf.pageNotes where pageNote(id: snapshot.id) == nil {
                let note = PageNote(pageIndex: snapshot.pageIndex, pageLabel: snapshot.pageLabel, text: snapshot.text, now: snapshot.createdAt)
                note.id = snapshot.id
                note.modifiedAt = snapshot.modifiedAt ?? snapshot.createdAt
                context.insert(note)
                note.entry = entry
            }
            restored.append(entry)
        }
        guard !restored.isEmpty else { return [] }
        save()
        searchIndex?.index(highlights.compactMap(SpotlightHighlight.init))
        // The text index keeps a removed PDF's text until Sheaf next opens,
        // so this is usually quick; it reads the file again if needed.
        TextIndexer.shared.index(restored)
        return restored
    }

    /// Changes the title Sheaf shows for a PDF. The file keeps its name.
    /// Returns false if the new title is empty or the same.
    @discardableResult
    func rename(_ entry: LibraryEntry, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.title else { return false }
        entry.title = trimmed
        save()
        // Each Spotlight result says which PDF its highlight is in.
        searchIndex?.index(entry.highlights.compactMap(SpotlightHighlight.init))
        return true
    }

    /// Every collection, oldest first, as in the left panel.
    func allCollections() -> [PDFCollection] {
        (try? context.fetch(FetchDescriptor<PDFCollection>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func collection(id: UUID) -> PDFCollection? {
        let descriptor = FetchDescriptor<PDFCollection>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    func pageNote(id: UUID) -> PageNote? {
        let descriptor = FetchDescriptor<PageNote>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func hasEntry(atPath path: String) -> Bool {
        let descriptor = FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.lastKnownPath == path })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}
