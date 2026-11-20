import Foundation
import PDFKit

/// The text of each PDF in the library, page by page, so the library's
/// search can find words inside PDFs and not only in titles and highlights.
///
/// Reading a PDF's text takes a while, so it's done once and kept in Sheaf's
/// own storage, one file per PDF (`<entry id>.json`). A saved text is used
/// until the file's size or modification date changes; then it's read again.
/// Everything here runs away from the main thread.
actor TextIndex {
    /// One PDF's text, as saved on disk.
    nonisolated struct Document: Codable, Sendable {
        /// Raised when the format changes, so older files are read again.
        static let currentVersion = 1

        var version = Document.currentVersion
        /// The file's size and modification date when its text was read.
        var fileSize: Int
        var modifiedAt: Date
        /// Each page's text, made easy to search (see `normalize`).
        var pages: [String]
    }

    /// A file's size and modification date. When either changes, the PDF's
    /// text is read again.
    nonisolated struct Stamp: Sendable, Equatable {
        let size: Int
        let modifiedAt: Date

        init(size: Int, modifiedAt: Date) {
            self.size = size
            self.modifiedAt = modifiedAt
        }

        /// The stamp of a file on disk, or `nil` if it can't be read.
        /// (FileManager is asked each time; URLs cache what they've read.)
        init?(of url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  let date = attributes[.modificationDate] as? Date
            else { return nil }
            self.init(size: size, modifiedAt: date)
        }
    }

    /// Where the search found the text in one PDF.
    nonisolated struct Match: Sendable, Identifiable, Equatable {
        nonisolated struct Page: Sendable, Identifiable, Equatable {
            /// 0-based.
            let index: Int
            /// The words around the first place the text appears on this page.
            let snippet: String
            var id: Int { index }
        }

        let entryID: UUID
        /// The first few pages with the text, in page order.
        let pages: [Page]
        /// How many pages contain the text, including those not in `pages`.
        let pageCount: Int

        var id: UUID { entryID }
    }

    /// Sheaf's own text index, in Application Support inside its container.
    nonisolated static var standardDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Text Index", directoryHint: .isDirectory)
    }

    /// Case and accents don't matter, as in the rest of the library's search.
    nonisolated static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    let directory: URL
    /// Texts read from disk so far, kept for the next search.
    private var documents: [UUID: Document] = [:]
    /// PDFs with no saved text, so the disk isn't asked again each search.
    private var unsaved = Set<UUID>()

    init(directory: URL) {
        self.directory = directory
    }

    /// Whether the saved text was read from the file as it is now.
    func isCurrent(_ id: UUID, stamp: Stamp) -> Bool {
        guard let document = document(for: id) else { return false }
        return document.version == Document.currentVersion
            && document.fileSize == stamp.size
            && abs(document.modifiedAt.timeIntervalSince(stamp.modifiedAt)) < 0.001
    }

    /// Saves a PDF's text, read from a file with this stamp.
    func store(_ pages: [String], for id: UUID, stamp: Stamp) {
        let document = Document(fileSize: stamp.size, modifiedAt: stamp.modifiedAt, pages: pages)
        documents[id] = document
        unsaved.remove(id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: file(for: id), options: .atomic)
        } catch {
            // Still searchable this session; it's read again next time.
            NSLog("Sheaf: couldn\u{2019}t save the text index for \(id): \(error)")
        }
    }

    /// The saved text of each page, if there is one.
    func pages(for id: UUID) -> [String]? {
        document(for: id)?.pages
    }

    /// Forgets the text of PDFs no longer in the library.
    func removeAll(except kept: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        documents = documents.filter { kept.contains($0.key) }
    }

    /// The PDFs among `ids` whose text contains `query`, in the same order.
    /// Each match has the first few pages with a snippet around the text.
    func search(_ query: String, in ids: [UUID], pagesPerMatch: Int = 3) -> [Match] {
        let query = Self.normalize(query)
        // One letter would match nearly every page of every PDF.
        guard query.count >= 2 else { return [] }
        var matches: [Match] = []
        for id in ids {
            // A newer search has started (the query changed).
            if Task.isCancelled { return [] }
            guard let pages = document(for: id)?.pages else { continue }
            var shown: [Match.Page] = []
            var count = 0
            for (index, text) in pages.enumerated() {
                guard let range = text.range(of: query, options: Self.searchOptions) else { continue }
                count += 1
                if shown.count < pagesPerMatch {
                    shown.append(Match.Page(index: index, snippet: Self.snippet(in: text, around: range)))
                }
            }
            if count > 0 {
                matches.append(Match(entryID: id, pages: shown, pageCount: count))
            }
        }
        return matches
    }

    private func document(for id: UUID) -> Document? {
        if let document = documents[id] { return document }
        guard !unsaved.contains(id) else { return nil }
        guard let data = try? Data(contentsOf: file(for: id)),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            unsaved.insert(id)
            return nil
        }
        documents[id] = document
        return document
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    // MARK: Reading PDFs

    /// Reads every page's text. Returns `nil` if the file isn't a PDF Sheaf
    /// can open, or needs a password. Coordinated with Sheaf's own saves, so
    /// a PDF is never read while its highlights are being written into it.
    nonisolated static func readText(of url: URL) -> [String]? {
        var pages: [String]?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { target in
            // Read into memory rather than letting PDFKit map the file, so a
            // save into it meanwhile can't pull the data away.
            guard let data = try? Data(contentsOf: target), let document = PDFDocument(data: data), !document.isLocked else { return }
            pages = (0..<document.pageCount).map { index in
                autoreleasepool { normalize(document.page(at: index)?.string ?? "") }
            }
        }
        return pages
    }

    /// Page text made easy to search: ligatures like "ﬁ" become "fi", words
    /// broken with a hyphen at the end of a line are joined again, and every
    /// run of spaces and line breaks becomes one space.
    nonisolated static func normalize(_ text: String) -> String {
        let lines = text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var result = ""
        for line in lines {
            if let last = result.last {
                // "repre-" + "sentation" is one word; "Figure 3-" + "B" is left alone.
                if last == "-", result.dropLast().last?.isLowercase == true, line.first?.isLowercase == true {
                    result.removeLast()
                } else {
                    result.append(" ")
                }
            }
            result += line
        }
        return result
    }

    /// The words around a match, cut at word boundaries, with "…" where the
    /// page text goes on.
    nonisolated static func snippet(in text: String, around range: Range<String.Index>, before: Int = 50, after: Int = 110) -> String {
        var start = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        if start > text.startIndex, let space = text[start..<range.lowerBound].firstIndex(of: " ") {
            start = text.index(after: space)
        }
        if end < text.endIndex, let space = text[range.upperBound..<end].lastIndex(of: " ") {
            end = space
        }
        var snippet = String(text[start..<end])
        if start > text.startIndex { snippet = "\u{2026}" + snippet }
        if end < text.endIndex { snippet += "\u{2026}" }
        return snippet
    }
}
