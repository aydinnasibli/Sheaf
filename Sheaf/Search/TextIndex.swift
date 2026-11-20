import Darwin
import Foundation
import PDFKit

/// The text of each PDF in the library, page by page, so the library's
/// search can find words inside PDFs and not only in titles and highlights.
///
/// Reading a PDF's text takes a while, so it's done once and kept in Sheaf's
/// own storage, one file per PDF (`<entry id>.sheaftext`). A saved text is
/// used until the file's size or modification date changes; then it's read
/// again. Scanned pages, which have no text of their own, get the words the
/// reader read off their pictures (see `RecognizedTextCache`), once it has.
///
/// The saved files aren't read into memory: each is mapped, so macOS reads
/// it from the disk as a search goes through it and lets go of it again
/// when memory is needed. A big library's text never piles up in Sheaf's
/// memory. Each file also has a copy of the text with case and accents
/// taken out, so a search compares plain bytes and is quick.
/// Everything here runs away from the main thread.
actor TextIndex {
    /// One PDF's text, as read from the file.
    nonisolated struct Contents: Sendable, Equatable {
        /// Each page's text, made easy to search (see `normalize`).
        var pages: [String]
        /// The PDF's printed page labels ("xii", "245"), one per page, or
        /// none when they're just 1, 2, 3…
        var labels: [String] = []
        /// The pages with no text of their own (scanned), with a fingerprint
        /// of each, so words read off them later can be checked against it.
        var scannedPages: [ScannedPageInfo] = []
        /// The scanned pages whose text was read off the picture.
        var recognizedPages: Set<Int> = []

        /// Puts in the words the reader read off scanned pages.
        mutating func add(_ recognized: [RecognizedPage]) {
            let scanned = Set(scannedPages.map(\.index))
            for page in recognized where scanned.contains(page.index) && pages.indices.contains(page.index) {
                let text = TextIndex.normalize(page.lines.map(\.text).joined(separator: "\n"))
                guard !text.isEmpty else { continue }
                pages[page.index] = text
                recognizedPages.insert(page.index)
            }
        }
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

        func matches(size: Int, modifiedAt: Date) -> Bool {
            self.size == size && abs(self.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001
        }
    }

    /// Whether a PDF's saved text is up to date.
    nonisolated enum Freshness: Sendable, Equatable {
        /// It was read from the file as it is now.
        case current
        /// The file is the same, but the reader has read more of its
        /// scanned pages since: these, out of `pageCount` pages.
        case needsRecognizedText(pageCount: Int, scanned: [ScannedPageInfo])
        /// There's none, or the file has changed: read it again.
        case stale
    }

    /// Where the search found the text in one PDF.
    nonisolated struct Match: Sendable, Identifiable, Equatable {
        nonisolated struct Page: Sendable, Identifiable, Equatable {
            /// 0-based.
            let index: Int
            /// The words around the first place the text appears on this page.
            let snippet: String
            /// The page's printed label ("xii", "245"), if the PDF has labels.
            var label: String?
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

    /// Raised when what's saved changes, so older files are read again.
    nonisolated static let currentVersion = 2
    private nonisolated static let fileExtension = "sheaftext"
    private nonisolated static let magic = Data("SHTX".utf8)

    let directory: URL
    /// Saved texts opened so far: their headers, and the files mapped.
    private var opened: [UUID: Saved] = [:]
    /// PDFs with no saved text, so the disk isn't asked again each search.
    private var unsaved = Set<UUID>()

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: Saving

    /// Whether the saved text is up to date with the file, which has this
    /// stamp, and the reader's text from its scanned pages, saved at
    /// `recognizedTextDate` (nil if there's none).
    func freshness(of id: UUID, stamp: Stamp, recognizedTextDate: Date?) -> Freshness {
        guard let saved = saved(for: id), saved.header.version == Self.currentVersion,
              stamp.matches(size: saved.header.fileSize, modifiedAt: saved.header.modifiedAt)
        else { return .stale }
        guard saved.hasScannedPages, let recognizedTextDate,
              saved.header.recognizedTextDate.map({ abs($0.timeIntervalSince(recognizedTextDate)) >= 0.001 }) ?? true,
              let scanned = Self.header(in: saved.data)?.header.scannedPages
        else { return .current }
        return .needsRecognizedText(pageCount: saved.pageCount, scanned: scanned)
    }

    /// Whether the saved text was read from the file as it is now.
    func isCurrent(_ id: UUID, stamp: Stamp) -> Bool {
        freshness(of: id, stamp: stamp, recognizedTextDate: nil) == .current
    }

    /// Saves a PDF's text, read from a file with this stamp.
    func store(_ contents: Contents, for id: UUID, stamp: Stamp, recognizedTextDate: Date? = nil) {
        let header = Header(
            version: Self.currentVersion, fileSize: stamp.size, modifiedAt: stamp.modifiedAt,
            recognizedTextDate: recognizedTextDate, labels: contents.labels,
            scannedPages: contents.scannedPages, recognizedPages: contents.recognizedPages.sorted(),
            textEnds: [], foldedEnds: []
        )
        write(contents.pages, header: header, for: id)
    }

    /// Saves a PDF's text, one string per page.
    func store(_ pages: [String], for id: UUID, stamp: Stamp) {
        store(Contents(pages: pages), for: id, stamp: stamp)
    }

    /// Puts in the words read off scanned pages since the text was saved,
    /// for a file that hasn't changed. `date` is when they were saved.
    func addRecognizedText(_ recognized: [RecognizedPage], for id: UUID, date: Date) {
        guard let saved = saved(for: id), var header = Self.header(in: saved.data)?.header else { return }
        var contents = Contents(
            pages: saved.allPages(), labels: header.labels,
            scannedPages: header.scannedPages, recognizedPages: Set(header.recognizedPages)
        )
        contents.add(recognized)
        header.recognizedTextDate = date
        header.recognizedPages = contents.recognizedPages.sorted()
        write(contents.pages, header: header, for: id)
    }

    /// The saved text of each page, if there is one.
    func pages(for id: UUID) -> [String]? {
        saved(for: id)?.allPages()
    }

    /// Forgets the text of PDFs no longer in the library.
    func removeAll(except kept: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == Self.fileExtension || file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        opened = opened.filter { kept.contains($0.key) }
    }

    // MARK: Searching

    /// The PDFs among `ids` whose text contains `query`, in the same order.
    /// Each match has the first few pages with a snippet around the text.
    func search(_ query: String, in ids: [UUID], pagesPerMatch: Int = 3) -> [Match] {
        let query = Self.normalize(query)
        // One letter would match nearly every page of every PDF.
        guard query.count >= 2 else { return [] }
        let needle = Array(Self.fold(query).utf8)
        guard !needle.isEmpty else { return [] }
        var matches: [Match] = []
        for id in ids {
            // A newer search has started (the query changed).
            if Task.isCancelled { return [] }
            guard let saved = saved(for: id) else { continue }
            let found = saved.pages(containing: needle)
            guard !found.isEmpty else { continue }
            let shown = found.prefix(pagesPerMatch).map { index in
                Match.Page(index: index, snippet: saved.snippet(onPage: index, for: query), label: saved.label(ofPage: index))
            }
            matches.append(Match(entryID: id, pages: shown, pageCount: found.count))
        }
        return matches
    }

    // MARK: Files

    /// How Sheaf saved a PDF's text before version 2.
    private nonisolated struct Version1: Decodable {
        var fileSize: Int
        var modifiedAt: Date
        var pages: [String]
    }

    /// What's saved before the text in each file.
    private nonisolated struct Header: Codable, Sendable {
        var version: Int
        var fileSize: Int
        var modifiedAt: Date
        /// When the reader's text from scanned pages that's in here was saved.
        var recognizedTextDate: Date?
        var labels: [String]
        var scannedPages: [ScannedPageInfo]
        var recognizedPages: [Int]
        /// Where each page's text ends, in bytes from the start of the text;
        /// then the same for the folded text (see `fold`), which follows it.
        var textEnds: [Int]
        var foldedEnds: [Int]
    }

    /// One PDF's saved text: its file, mapped, and what's needed to search it.
    private nonisolated struct Saved: Sendable {
        /// Without the scanned pages' fingerprints, which a search doesn't need.
        let header: Header
        let hasScannedPages: Bool
        let data: Data
        /// Where the text starts in the file.
        let textStart: Int

        var pageCount: Int { header.textEnds.count }

        func text(ofPage index: Int) -> String {
            let start = textStart + (index == 0 ? 0 : header.textEnds[index - 1])
            return String(decoding: data[start..<(textStart + header.textEnds[index])], as: UTF8.self)
        }

        func allPages() -> [String] {
            (0..<pageCount).map(text(ofPage:))
        }

        func label(ofPage index: Int) -> String? {
            header.labels.count == pageCount ? header.labels[index] : nil
        }

        /// The pages whose folded text contains `needle`, in order.
        func pages(containing needle: [UInt8]) -> [Int] {
            data.withUnsafeBytes { raw -> [Int] in
                guard let base = raw.baseAddress else { return [] }
                return needle.withUnsafeBytes { query -> [Int] in
                    var found: [Int] = []
                    var start = textStart + (header.textEnds.last ?? 0)
                    for (index, end) in header.foldedEnds.enumerated() {
                        let pageEnd = textStart + end
                        if pageEnd - start >= needle.count,
                           memmem(base + start, pageEnd - start, query.baseAddress, needle.count) != nil {
                            found.append(index)
                        }
                        start = pageEnd
                    }
                    return found
                }
            }
        }

        /// The words around the first place `query` is on the page.
        func snippet(onPage index: Int, for query: String) -> String {
            let text = text(ofPage: index)
            if let range = text.range(of: query, options: TextIndex.searchOptions) {
                return TextIndex.snippet(in: text, around: range)
            }
            // Folding found it where comparing didn't: show the folded words.
            let folded = TextIndex.fold(text)
            let range = folded.range(of: TextIndex.fold(query)) ?? folded.startIndex..<folded.startIndex
            return TextIndex.snippet(in: folded, around: range)
        }
    }

    private func saved(for id: UUID) -> Saved? {
        if let saved = opened[id] { return saved }
        guard !unsaved.contains(id) else { return nil }
        if let data = try? Data(contentsOf: file(for: id), options: .alwaysMapped), let saved = Self.saved(from: data) {
            opened[id] = saved
            return saved
        }
        if let saved = migrateVersion1(id) {
            return saved
        }
        unsaved.insert(id)
        return nil
    }

    /// Text saved by Sheaf before version 2, in JSON, is kept for searching
    /// until the PDF is read again (it's marked out of date).
    private func migrateVersion1(_ id: UUID) -> Saved? {
        let old = directory.appending(path: "\(id.uuidString).json")
        guard let data = try? Data(contentsOf: old) else { return nil }
        try? FileManager.default.removeItem(at: old)
        guard let document = try? JSONDecoder().decode(Version1.self, from: data) else { return nil }
        let header = Header(
            version: 1, fileSize: document.fileSize, modifiedAt: document.modifiedAt, recognizedTextDate: nil,
            labels: [], scannedPages: [], recognizedPages: [], textEnds: [], foldedEnds: []
        )
        write(document.pages, header: header, for: id)
        return opened[id]
    }

    /// Writes the file, and maps it for searching. If it can't be written,
    /// it's still searchable this session, from memory.
    private func write(_ pages: [String], header: Header, for id: UUID) {
        unsaved.remove(id)
        guard let data = Self.encode(pages, header: header) else { return }
        let url = file(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Atomic, so a file that's mapped is replaced, never changed under it.
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Sheaf: couldn\u{2019}t save the text index for \(id): \(error)")
            opened[id] = Self.saved(from: data)
            return
        }
        opened[id] = (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap(Self.saved(from:)) ?? Self.saved(from: data)
    }

    private func file(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).\(Self.fileExtension)")
    }

    /// "SHTX", the header's length (4 bytes, little-endian), the header as
    /// JSON, then every page's text, then every page's folded text.
    private nonisolated static func encode(_ pages: [String], header: Header) -> Data? {
        var header = header
        var text = Data()
        header.textEnds = pages.map { page in
            text.append(contentsOf: page.utf8)
            return text.count
        }
        header.foldedEnds = pages.map { page in
            text.append(contentsOf: fold(page).utf8)
            return text.count
        }
        guard let json = try? JSONEncoder().encode(header), let length = UInt32(exactly: json.count) else { return nil }
        var data = magic
        withUnsafeBytes(of: length.littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(text)
        return data
    }

    private nonisolated static func saved(from data: Data) -> Saved? {
        guard let found = Self.header(in: data) else { return nil }
        var header = found.header
        let textStart = found.textStart
        let hasScannedPages = !header.scannedPages.isEmpty
        header.scannedPages = []
        return Saved(header: header, hasScannedPages: hasScannedPages, data: data, textStart: textStart)
    }

    /// The header of a saved file, checked so searching can trust it.
    private nonisolated static func header(in data: Data) -> (header: Header, textStart: Int)? {
        guard data.startIndex == 0, data.count >= 8, data.prefix(4) == magic else { return nil }
        let length = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
        guard data.count >= 8 + length,
              let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 8..<(8 + length)))
        else { return nil }
        let textStart = 8 + length
        let ends = header.textEnds + header.foldedEnds
        guard header.textEnds.count == header.foldedEnds.count,
              zip(ends, ends.dropFirst()).allSatisfy({ $0 <= $1 }),
              (ends.first ?? 0) >= 0, textStart + (ends.last ?? 0) <= data.count
        else { return nil }
        return (header, textStart)
    }

    // MARK: Reading PDFs

    /// Reads every page's text, and the printed page labels. Pages without
    /// text get the words the reader read off them, if it kept any in
    /// `recognizedTextFolder` (filed under `libraryID`). Returns `nil` if the
    /// file isn't a PDF Sheaf can open, or needs a password. Coordinated with
    /// Sheaf's own saves, so a PDF is never read while its highlights are
    /// being written into it.
    nonisolated static func read(_ url: URL, libraryID: UUID?, recognizedTextFolder: URL?) -> Contents? {
        var contents: Contents?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { target in
            // Read into memory rather than letting PDFKit map the file, so a
            // save into it meanwhile can't pull the data away.
            guard let data = try? Data(contentsOf: target), let document = PDFDocument(data: data), !document.isLocked else { return }
            contents = read(document)
        }
        guard var contents else { return nil }
        if !contents.scannedPages.isEmpty, let recognizedTextFolder,
           let cache = RecognizedTextCache(fileURL: url, libraryID: libraryID, folder: recognizedTextFolder) {
            contents.add(cache.load(pageCount: contents.pages.count, current: contents.scannedPages))
        }
        return contents
    }

    /// Every page's text and the printed labels of a PDF that's open, in
    /// one pass over its pages.
    nonisolated static func read(_ document: PDFDocument) -> Contents {
        var pages: [String] = []
        var labels: [String?] = []
        var scanned: [ScannedPageInfo] = []
        for index in 0..<document.pageCount {
            autoreleasepool {
                guard let page = document.page(at: index) else {
                    pages.append("")
                    labels.append(nil)
                    return
                }
                let text = normalize(page.string ?? "")
                if text.isEmpty {
                    scanned.append(ScannedPageInfo(index: index, fingerprint: PageText.fingerprint(of: page)))
                }
                pages.append(text)
                labels.append(page.label)
            }
        }
        return Contents(pages: pages, labels: PageLabels.cleaned(labels), scannedPages: scanned)
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

    /// Text with case, accents and full-width letters taken out, so "Café"
    /// and "CAFE" are the same bytes, as `searchOptions` compares them.
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: searchOptions, locale: nil)
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
