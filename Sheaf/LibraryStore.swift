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

    /// Files Sheaf is currently allowed to read through a bookmark.
    @ObservationIgnored private var accessedURLs = Set<URL>()

    init(context: ModelContext) {
        self.context = context
    }

    /// Creates the on-disk library used by the app.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: LibraryEntry.self, PDFCollection.self, configurations: configuration)
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

    /// Removes PDFs from the library. The files themselves are left alone.
    func remove(_ items: [LibraryEntry]) {
        for item in items { context.delete(item) }
        save()
    }

    @discardableResult
    func createCollection(named name: String, now: Date = .now) -> PDFCollection {
        let count = (try? context.fetchCount(FetchDescriptor<PDFCollection>())) ?? 0
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = PDFCollection(name: trimmed.isEmpty ? "Untitled Collection" : trimmed, colorIndex: count, now: now)
        context.insert(collection)
        save()
        return collection
    }

    func rename(_ collection: PDFCollection, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collection.name = trimmed
        save()
    }

    /// Deletes a collection. Its PDFs stay in the library.
    func delete(_ collection: PDFCollection) {
        context.delete(collection)
        save()
    }

    func save() {
        try? context.save()
    }

    // MARK: Helpers

    private func existingItem(for url: URL) -> LibraryEntry? {
        let path = Self.path(of: url)
        let descriptor = FetchDescriptor<LibraryEntry>(predicate: #Predicate { $0.lastKnownPath == path })
        return try? context.fetch(descriptor).first
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
