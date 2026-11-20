import AppKit
import Foundation
import Observation
import PDFKit
import SwiftData

/// Adds PDFs to the library, finds their files again, and keeps the
/// library's bookkeeping (reading position, last opened) up to date.
@Observable
final class LibraryStore {
    let context: ModelContext
    /// True when the library couldn't be opened and this session uses a
    /// temporary one instead. Then nothing is written into PDF files: the
    /// library can't keep track of what was written.
    let isTemporaryLibrary: Bool
    /// Where a copy of each PDF is kept before Sheaf first writes highlights
    /// into it. `nil` keeps no copies (in tests).
    let originalsFolder: URL?
    /// Why the library couldn't be saved, for the window to show. Cleared by
    /// the next save that works.
    private(set) var saveError: String?
    /// Goes up when a collection is made, renamed or deleted, so menus that
    /// list collections outside SwiftUI's queries (the menu bar) update.
    private(set) var collectionChanges = 0

    /// Files Sheaf is currently allowed to read through a bookmark.
    @ObservationIgnored private var accessedURLs = Set<URL>()
    /// Spotlight's copy of the highlights, kept current by the highlight
    /// methods below. `nil` in tests, which never touch Spotlight.
    @ObservationIgnored var searchIndex: (any HighlightIndexing)?

    init(context: ModelContext, isTemporaryLibrary: Bool = false, originalsFolder: URL? = nil) {
        self.context = context
        self.isTemporaryLibrary = isTemporaryLibrary
        self.originalsFolder = originalsFolder
    }

    /// Creates the on-disk library used by the app.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: LibraryEntry.self, PDFCollection.self, HighlightRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }

    /// Opens the app's library. On disk, its files are first copied into
    /// Library Backups. If it can't be opened, a temporary library is used
    /// so Sheaf still works, and `isTemporary` is true.
    static func openLibrary(inMemory: Bool) -> (container: ModelContainer, isTemporary: Bool) {
        let storeURL = inMemory ? nil : ModelConfiguration(isStoredInMemoryOnly: false).url
        let backup = storeURL.flatMap { LibraryBackup.backUp(storeURL: $0) }
        do {
            let container = try makeContainer(inMemory: inMemory)
            if let storeURL { LibraryBackup.prune(LibraryBackup.folder(for: storeURL)) }
            return (container, false)
        } catch {
            NSLog("Sheaf: couldn\u{2019}t open the library (\(error)); using a temporary one.")
            // A copy of a library that won't open would only push good backups out.
            if let backup { try? FileManager.default.removeItem(at: backup) }
            return (try! makeContainer(inMemory: true), true)
        }
    }

    func entry(id: UUID) -> LibraryEntry? {
        let descriptor = FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    // MARK: Highlights

    @discardableResult
    func addHighlight(
        to entry: LibraryEntry, pageIndex: Int, kind: HighlightKind, text: String, rects: [CGRect], now: Date = .now
    ) -> HighlightRecord {
        let record = HighlightRecord(pageIndex: pageIndex, kind: kind, text: text, rects: rects, now: now)
        context.insert(record)
        record.entry = entry
        entry.needsFileSave = true
        save()
        searchIndex?.index(record)
        return record
    }

    /// Brings back a deleted highlight with its original ID (for Undo).
    @discardableResult
    func restoreHighlight(_ snapshot: HighlightSnapshot, to entry: LibraryEntry) -> HighlightRecord {
        let record = insertRecord(
            id: snapshot.id, into: entry, pageIndex: snapshot.pageIndex,
            kind: HighlightKind(rawValue: snapshot.kindRaw) ?? .keyIdea,
            text: snapshot.text, note: snapshot.note, rects: snapshot.rects, createdAt: snapshot.createdAt
        )
        entry.removedHighlightIDs.removeAll { $0 == snapshot.id }
        entry.needsFileSave = true
        save()
        return record
    }

    /// Adds highlights found in the PDF file that this entry doesn't have,
    /// with the same IDs, so the file's highlights are never forgotten (it
    /// was removed from the library and opened again, say). Highlights
    /// deleted in Sheaf whose removal hasn't reached the file are skipped.
    /// Returns how many were added.
    @discardableResult
    func importHighlights(_ found: [PDFHighlightImport.Found], into entry: LibraryEntry) -> Int {
        var known = knownHighlightIDs(of: entry)
        var count = 0
        for highlight in found where known.insert(highlight.id).inserted {
            insertRecord(
                id: highlight.id, into: entry, pageIndex: highlight.pageIndex,
                kind: .nearest(toColorHex: highlight.colorHex),
                text: highlight.text, note: highlight.note, rects: highlight.rects, createdAt: highlight.createdAt
            )
            count += 1
        }
        if count > 0 { save() }
        return count
    }

    /// IDs a file's highlights are checked against when it opens: the
    /// entry's highlights, and ones deleted that may still be in the file.
    func knownHighlightIDs(of entry: LibraryEntry) -> Set<UUID> {
        Set(entry.highlights.map(\.id)).union(entry.removedHighlightIDs)
    }

    @discardableResult
    private func insertRecord(
        id: UUID, into entry: LibraryEntry, pageIndex: Int, kind: HighlightKind,
        text: String, note: String, rects: [CGRect], createdAt: Date
    ) -> HighlightRecord {
        let record = HighlightRecord(pageIndex: pageIndex, kind: kind, text: text, rects: rects, now: createdAt)
        record.id = id
        record.note = note
        context.insert(record)
        record.entry = entry
        // Callers save; Spotlight learns about the highlight either way.
        searchIndex?.index(record)
        return record
    }

    func setNote(_ note: String, for record: HighlightRecord) {
        record.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        record.entry?.needsFileSave = true
        save()
        searchIndex?.index(record)
    }

    func setKind(_ kind: HighlightKind, for record: HighlightRecord) {
        record.kind = kind
        record.entry?.needsFileSave = true
        save()
        searchIndex?.index(record)
    }

    func delete(_ record: HighlightRecord) {
        let id = record.id
        if let entry = record.entry {
            if !entry.removedHighlightIDs.contains(record.id) {
                entry.removedHighlightIDs.append(record.id)
            }
            entry.needsFileSave = true
        }
        context.delete(record)
        save()
        searchIndex?.remove(highlightIDs: [id])
    }

    /// Records that highlights were written into the entry's file: the
    /// deletions in `removed` reached it, and if nothing changed meanwhile
    /// the file is up to date.
    func didWriteHighlights(of entry: LibraryEntry, to url: URL, removed: Set<UUID>, isUpToDate: Bool) {
        guard entry.modelContext != nil, !entry.isDeleted else { return }
        if !removed.isEmpty {
            entry.removedHighlightIDs.removeAll { removed.contains($0) }
        }
        if isUpToDate {
            entry.needsFileSave = false
        }
        // Saving replaces the file with a new one, which a bookmark made
        // before can't follow if the file is moved later.
        if let fresh = Self.makeBookmark(for: url) {
            entry.bookmark = fresh
        }
        save()
    }

    // MARK: Adding and opening

    /// Records that a PDF was opened: adds it to the library the first time,
    /// and updates "last opened" after that. Call while Sheaf has access to
    /// the file (it was just opened, dropped or picked).
    @discardableResult
    func recordOpen(of url: URL, document: PDFDocument, now: Date = .now) -> LibraryEntry {
        let item = existingItem(for: url) ?? addItem(for: url, document: document, now: now)
        item.lastOpenedAt = now
        item.lastKnownPath = Self.path(of: url)
        item.pageCount = document.pageCount
        if item.bookmark == nil {
            item.bookmark = Self.makeBookmark(for: url)
        }
        if item.cover == nil {
            item.cover = Self.coverImage(for: document)
        }
        save()
        return item
    }

    /// Adds PDFs without opening them, for drag and drop and the Add command.
    /// Returns the items, new or existing, in the same order.
    @discardableResult
    func add(urls: [URL], now: Date = .now) -> [LibraryEntry] {
        var items: [LibraryEntry] = []
        for url in urls {
            if let existing = existingItem(for: url) {
                items.append(existing)
                continue
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let document = PDFDocument(url: url) else { continue }
            let item = addItem(for: url, document: document, now: now)
            item.bookmark = Self.makeBookmark(for: url)
            item.cover = Self.coverImage(for: document)
            items.append(item)
        }
        save()
        return items
    }

    /// Keeps access to a file the user picked, for the rest of the session.
    func keepAccess(to url: URL) {
        if !accessedURLs.contains(url), url.startAccessingSecurityScopedResource() {
            accessedURLs.insert(url)
        }
    }

    /// The file for a library item, ready to open, or `nil` if it can't be found.
    func resolveFile(for item: LibraryEntry) -> URL? {
        guard let bookmark = item.bookmark else {
            let url = URL(filePath: item.lastKnownPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        // Keep access for the rest of the session: the reader window needs it
        // to read the file now and to save highlights into it later.
        keepAccess(to: url)
        if isStale, let fresh = Self.makeBookmark(for: url) {
            item.bookmark = fresh
        }
        item.lastKnownPath = Self.path(of: url)
        save()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Editing

    func setStarred(_ starred: Bool, for items: [LibraryEntry]) {
        for item in items { item.isStarred = starred }
        save()
    }

    func move(_ items: [LibraryEntry], to collection: PDFCollection?) {
        for item in items { item.collection = collection }
        save()
    }

    @discardableResult
    func createCollection(named name: String, now: Date = .now) -> PDFCollection {
        let count = (try? context.fetchCount(FetchDescriptor<PDFCollection>())) ?? 0
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = PDFCollection(name: trimmed.isEmpty ? "Untitled Collection" : trimmed, colorIndex: count, now: now)
        context.insert(collection)
        save()
        collectionChanges += 1
        return collection
    }

    func rename(_ collection: PDFCollection, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collection.name = trimmed
        save()
        collectionChanges += 1
    }

    /// Deletes a collection. Its PDFs stay in the library.
    func delete(_ collection: PDFCollection) {
        context.delete(collection)
        save()
        collectionChanges += 1
    }

    func save() {
        do {
            try context.save()
            if saveError != nil { saveError = nil }
        } catch {
            NSLog("Sheaf: couldn\u{2019}t save the library: \(error)")
            saveError = "Sheaf couldn\u{2019}t save your library (\(error.localizedDescription)). Your latest changes may be lost if Sheaf quits."
        }
    }

    // MARK: Helpers

    /// The entry for a file: the one last seen at its path or, if none,
    /// one whose file was moved or renamed to it since.
    private func existingItem(for url: URL) -> LibraryEntry? {
        let path = Self.path(of: url)
        let descriptor = FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.lastKnownPath == path })
        if let item = try? context.fetch(descriptor).first { return item }
        return movedItem(at: url)
    }

    /// Finds the entry of a file that was moved or renamed to `url`, through
    /// the bookmark Sheaf keeps for each file (it follows the file itself,
    /// not its path), and updates where the entry's file is. Only entries
    /// whose file is gone from where it was are checked, so this is quick.
    private func movedItem(at url: URL) -> LibraryEntry? {
        let fileManager = FileManager.default
        let entries = (try? context.fetch(FetchDescriptor<LibraryEntry>())) ?? []
        let candidates = entries.filter { $0.bookmark != nil && !fileManager.fileExists(atPath: $0.lastKnownPath) }
        guard !candidates.isEmpty else { return nil }
        let target = Self.comparablePath(of: url)
        for item in candidates {
            guard let bookmark = item.bookmark else { continue }
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI, .withoutMounting],
                bookmarkDataIsStale: &isStale
            ), Self.comparablePath(of: resolved) == target else { continue }

            item.lastKnownPath = Self.path(of: url)
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            if let fresh = Self.makeBookmark(for: url) {
                item.bookmark = fresh
            }
            return item
        }
        return nil
    }

    private static func comparablePath(of url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    private func addItem(for url: URL, document: PDFDocument, now: Date) -> LibraryEntry {
        let item = LibraryEntry(title: Self.title(for: url), path: Self.path(of: url), pageCount: document.pageCount, now: now)
        context.insert(item)
        return item
    }

    /// The file name without ".pdf". PDF title metadata is often missing or
    /// junk ("Microsoft Word - draft3.docx"), so the file name is more reliable.
    static func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func path(of url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    private static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func coverImage(for document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 96, height: 124), for: .cropBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
