import Foundation

/// Keeps text read off scanned pages on disk, in Application Support/
/// Recognized Text/, so a PDF is read only once.
///
/// Each file is named after the PDF's library entry, which follows the file
/// when it's renamed, moved or saved by another app (saving often replaces
/// the file, so its number on the drive changes). Without an entry, the
/// file's number on the drive is used. The PDF's size and date are kept too,
/// but they change every time highlights are saved into it, so each page is
/// also checked against its fingerprint: a page whose scan is unchanged
/// keeps its text.
nonisolated struct RecognizedTextCache: Sendable {
    let fileURL: URL
    private let cacheURL: URL

    /// The folder in Sheaf's own storage. (Tests use a folder of their own.)
    static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Recognized Text", directoryHint: .isDirectory)
    }

    /// The most PDFs kept; the ones read longest ago are removed first.
    static let fileLimit = 300

    private struct Stored: Codable {
        var version = 1
        var fileSize: Int?
        var fileDate: Date?
        var pageCount: Int
        var pages: [RecognizedPage]
    }

    /// Nil if the PDF's identity can't be found out.
    init?(fileURL: URL, libraryID: UUID?, folder: URL) {
        guard let name = libraryID.map({ "entry-\($0.uuidString)" }) ?? Self.identity(of: fileURL) else { return nil }
        self.fileURL = fileURL
        self.cacheURL = folder.appending(path: name).appendingPathExtension("plist")
    }

    /// When text was last saved here, or nil if none has been. The library's
    /// text index takes the text in again when this changes.
    var savedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// Text read earlier, for the pages that haven't changed since.
    func load(pageCount: Int, current: [ScannedPageInfo]) -> [RecognizedPage] {
        guard let data = try? Data(contentsOf: cacheURL),
              let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
              stored.version == 1, stored.pageCount == pageCount
        else { return [] }
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let isUnchanged = stored.fileSize != nil && stored.fileSize == values?.fileSize
            && stored.fileDate != nil && stored.fileDate == values?.contentModificationDate
        let fingerprints = Dictionary(current.map { ($0.index, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        return stored.pages.filter { page in
            guard let fingerprint = fingerprints[page.index] else { return false }
            return isUnchanged || fingerprint == page.fingerprint
        }
    }

    func save(_ pages: [RecognizedPage], pageCount: Int) {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stored = Stored(
            fileSize: values?.fileSize, fileDate: values?.contentModificationDate,
            pageCount: pageCount, pages: pages.sorted { $0.index < $1.index }
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(stored) else { return }
        let folder = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        Self.removeOldFiles(in: folder)
    }

    /// The drive and the file's number on it; falls back to the path.
    private static func identity(of url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey])
        if let volume = values?.volumeUUIDString, let file = values?.fileIdentifier {
            return "\(volume)-\(file)"
        }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        guard !path.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "path-\(String(hash, radix: 16))"
    }

    private static func removeOldFiles(in folder: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)),
              files.count > fileLimit
        else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - fileLimit) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
