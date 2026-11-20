import AppKit
import Foundation
import ImageIO
import Observation
import PDFKit
import SwiftData
import UniformTypeIdentifiers

/// A deleted collection, kept by Undo: everything needed to bring it back.
nonisolated struct DeletedCollection: Sendable {
    let id: UUID
    let name: String
    let colorIndex: Int
    let createdAt: Date
    /// Its PDFs, by library ID.
    let entryIDs: [UUID]
}

extension DeletedCollection {
    init(_ collection: PDFCollection) {
        self.init(
            id: collection.id, name: collection.name, colorIndex: collection.colorIndex,
            createdAt: collection.createdAt, entryIDs: collection.items.map(\.id)
        )
    }
}

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

    /// Everything the library stores.
    static var models: [any PersistentModel.Type] {
        [LibraryEntry.self, PDFCollection.self, HighlightRecord.self, PageNote.self]
    }

    /// Creates the on-disk library used by the app.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(for: Schema(models), configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory))
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

    /// `pageLabel` is the page's printed label, if the PDF has labels.
    @discardableResult
    func addHighlight(
        to entry: LibraryEntry, pageIndex: Int, kind: HighlightKind, text: String, rects: [CGRect],
        pageLabel: String = "", now: Date = .now
    ) -> HighlightRecord {
        let record = HighlightRecord(pageIndex: pageIndex, kind: kind, text: text, rects: rects, now: now)
        record.pageLabel = pageLabel
        context.insert(record)
        record.entry = entry
        entry.needsFileSave = true
        save()
        searchIndex?.index(record)
        return record
    }

    /// Brings back a deleted highlight with its original ID (for Undo), and
    /// its page label: `pageLabel` if there is one, else the one it had.
    @discardableResult
    func restoreHighlight(_ snapshot: HighlightSnapshot, to entry: LibraryEntry, pageLabel: String? = nil) -> HighlightRecord {
        let pageLabel = pageLabel.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.pageLabel
        let record = insertRecord(
            id: snapshot.id, into: entry, pageIndex: snapshot.pageIndex,
            kind: HighlightKind(rawValue: snapshot.kindRaw) ?? .keyIdea,
            text: snapshot.text, note: snapshot.note, rects: snapshot.rects, createdAt: snapshot.createdAt
        )
        record.pageLabel = pageLabel
        record.isAnswered = snapshot.isAnswered
        record.answer = snapshot.answer
        entry.removedHighlightIDs.removeAll { $0 == snapshot.id }
        entry.needsFileSave = true
        save()
        // Spotlight first heard about it without the label and the answer.
        if !pageLabel.isEmpty || snapshot.isAnswered { searchIndex?.index(record) }
        return record
    }

    /// Adds highlights found in the PDF file that this entry doesn't have,
    /// with the same IDs, so the file's highlights are never forgotten (it
    /// was removed from the library and opened again, say). Highlights
    /// deleted in Sheaf whose removal hasn't reached the file are skipped.
    ///
    /// A highlight whose ID another PDF's highlight has already (the file is
    /// a copy of one in the library: duplicated in Finder, or moved to
    /// another drive) gets a new ID, and the next save writes it into the
    /// file in place of the old one. Returns how many were added.
    @discardableResult
    func importHighlights(_ found: [PDFHighlightImport.Found], into entry: LibraryEntry) -> Int {
        guard !found.isEmpty else { return 0 }
        var known = knownHighlightIDs(of: entry)
        var taken = takenHighlightIDs(besides: entry)
        var count = 0
        for highlight in found where known.insert(highlight.id).inserted {
            insertRecord(
                id: uniqueHighlightID(highlight.id, comingInto: entry, taken: &taken), into: entry,
                pageIndex: highlight.pageIndex, kind: .nearest(toColorHex: highlight.colorHex),
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

    /// Marks a Question answered, with her answer (which may be empty), or
    /// open again. Kept in the library only, like page notes, so unlike a
    /// note or a color it doesn't mark the PDF file as needing a save.
    func setAnswer(_ answer: String, isAnswered: Bool, for record: HighlightRecord) {
        record.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        record.isAnswered = isAnswered
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

    // MARK: Page notes and summaries

    // Kept in the library only, so unlike highlights they never mark the
    // PDF file as needing a save.

    /// `modifiedAt` is for Undo, bringing a note back as it was; a new
    /// note was last changed when it was written.
    @discardableResult
    func addPageNote(
        to entry: LibraryEntry, pageIndex: Int, pageLabel: String = "", text: String,
        id: UUID = UUID(), createdAt: Date = .now, modifiedAt: Date? = nil
    ) -> PageNote {
        let note = PageNote(pageIndex: pageIndex, pageLabel: pageLabel, text: text, now: createdAt)
        note.id = id
        if let modifiedAt { note.modifiedAt = modifiedAt }
        context.insert(note)
        note.entry = entry
        save()
        return note
    }

    func setText(_ text: String, for note: PageNote, now: Date = .now) {
        note.text = text
        note.modifiedAt = now
        save()
    }

    func delete(_ note: PageNote) {
        context.delete(note)
        save()
    }

    func setSummary(_ summary: String, for entry: LibraryEntry) {
        entry.summary = summary
        save()
    }

    // MARK: Adding and opening

    /// Records that a PDF was opened: adds it to the library the first time,
    /// and updates "last opened" after that. Call while Sheaf has access to
    /// the file (it was just opened, dropped or picked). `cover`, if the
    /// caller drew it already (away from the main thread), saves drawing it
    /// here for a PDF without one.
    @discardableResult
    func recordOpen(of url: URL, document: PDFDocument, cover: Data? = nil, now: Date = .now) -> LibraryEntry {
        let item = existingItem(for: url) ?? addItem(for: url, document: document, now: now)
        item.lastOpenedAt = now
        item.lastKnownPath = Self.path(of: url)
        item.pageCount = document.pageCount
        if item.bookmark == nil {
            item.bookmark = Self.makeBookmark(for: url)
        }
        if item.cover == nil {
            item.cover = cover ?? Self.coverImage(for: document)
        }
        save()
        return item
    }

    /// What adding a PDF needs from its file.
    nonisolated struct NewFile: Sendable {
        let url: URL
        let pageCount: Int
        /// A small picture of the first page, as PNG.
        let cover: Data?
        let bookmark: Data?
    }

    /// Adds PDFs without opening them, for drag and drop and the Add command.
    /// Returns the items, new or existing, in the same order; files that
    /// aren't PDFs are left out.
    ///
    /// PDFs already in the library (also ones moved or renamed since) are
    /// found here; only new ones are read, and their covers drawn, away from
    /// the main thread, so adding a big PDF or a slow drive's never freezes
    /// the window. The entries are made here once that's done.
    @discardableResult
    func addInBackground(urls: [URL], cloud: any CloudFiles = ICloudDrive(), now: Date = .now) async -> [LibraryEntry] {
        var paths = Set<String>()
        let toRead = urls.filter { existingItem(for: $0) == nil && paths.insert(Self.path(of: $0)).inserted }
        let read = toRead.isEmpty ? [] : await Task.detached(priority: .userInitiated) {
            toRead.compactMap { LibraryStore.readNewFile(at: $0, cloud: cloud) }
        }.value
        let byPath = Dictionary(read.map { (Self.path(of: $0.url), $0) }, uniquingKeysWith: { first, _ in first })
        // Looked for again: the same file may have been added meanwhile.
        let items = urls.compactMap { url in
            existingItem(for: url) ?? byPath[Self.path(of: url)].map { insert($0, now: now) }
        }
        save()
        return items
    }

    /// Like `addInBackground(urls:)`, but reads the files here, on the main
    /// thread. For tests, and the odd small file.
    @discardableResult
    func add(urls: [URL], now: Date = .now) -> [LibraryEntry] {
        let items = urls.compactMap { url in
            existingItem(for: url) ?? Self.readNewFile(at: url).map { insert($0, now: now) }
        }
        save()
        return items
    }

    /// Opens a PDF to add it: its page count, a picture of its first page
    /// and a bookmark to find it again. Nil if it isn't a PDF that opens.
    /// Runs on any thread; the PDF is only used here.
    ///
    /// A PDF in iCloud Drive that isn't on this Mac isn't opened, as that
    /// would download it (a whole folder of them, when a folder is added):
    /// it's added without a page count or cover, which opening it fills in.
    nonisolated static func readNewFile(at url: URL, cloud: any CloudFiles = ICloudDrive()) -> NewFile? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard cloud.status(of: url).isLocal else {
            return isPDF(url) ? NewFile(url: url, pageCount: 0, cover: nil, bookmark: makeBookmark(for: url)) : nil
        }
        guard let document = PDFDocument(url: url) else { return nil }
        return NewFile(url: url, pageCount: document.pageCount, cover: coverImage(for: document), bookmark: makeBookmark(for: url))
    }

    private func insert(_ file: NewFile, now: Date) -> LibraryEntry {
        let item = LibraryEntry(title: Self.title(for: file.url), path: Self.path(of: file.url), pageCount: file.pageCount, now: now)
        context.insert(item)
        item.bookmark = file.bookmark
        item.cover = file.cover
        return item
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

    /// Deletes a collection. Its PDFs stay in the library. Returns what
    /// Undo needs to bring it back (see `restore(_:)`).
    @discardableResult
    func delete(_ collection: PDFCollection) -> DeletedCollection {
        let deleted = DeletedCollection(collection)
        context.delete(collection)
        save()
        collectionChanges += 1
        return deleted
    }

    /// Brings back a deleted collection as it was: the same ID, name, color
    /// and place in the list, with its PDFs. A PDF put in another collection
    /// since stays there, and one removed from the library doesn't come
    /// back. Returns `nil` if the collection is back already.
    @discardableResult
    func restore(_ deleted: DeletedCollection) -> PDFCollection? {
        guard collection(id: deleted.id) == nil else { return nil }
        let collection = PDFCollection(name: deleted.name, colorIndex: deleted.colorIndex, now: deleted.createdAt)
        collection.id = deleted.id
        context.insert(collection)
        for entry in deleted.entryIDs.compactMap(entry(id:)) where entry.collection == nil {
            entry.collection = collection
        }
        save()
        collectionChanges += 1
        return collection
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
    nonisolated static func title(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    nonisolated static func path(of url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }

    private nonisolated static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// A small picture of the first page, as PNG. Drawn with Core Graphics,
    /// so it works on any thread (with a PDF only that thread uses).
    nonisolated static func coverImage(for document: PDFDocument) -> Data? {
        guard let page = document.page(at: 0),
              let image = PageImage.thumbnail(of: page, fitting: CGSize(width: 96, height: 124), highlights: [])
        else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
    }
}
