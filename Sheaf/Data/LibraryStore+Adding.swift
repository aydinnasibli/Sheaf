import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Adding PDFs by the handful or by the folder: drag and drop onto the
/// library, and folders chosen in File › Open.
extension LibraryStore {
    /// How many PDFs are added between pauses, so a big folder doesn't
    /// freeze the window.
    private static let batchSize = 8

    /// Adds PDFs and folders of PDFs. Folders add every PDF inside them,
    /// subfolders included. PDFs already in the library aren't added twice.
    ///
    /// With a collection, every PDF joins it, moving from another collection
    /// if it was in one: they were put there on purpose. With `starred`, every
    /// PDF is starred. The new PDFs' text is indexed for search.
    @discardableResult
    func addFiles(_ urls: [URL], to collection: PDFCollection? = nil, starred: Bool = false) async -> [LibraryEntry] {
        // Looking through folders reads the disk, so it happens in the background.
        let files = await Task.detached(priority: .userInitiated) { Self.pdfFiles(in: urls) }.value
        var added: [LibraryEntry] = []
        var seen = Set<UUID>()
        for start in stride(from: 0, to: files.count, by: Self.batchSize) {
            let batch = Array(files[start..<min(start + Self.batchSize, files.count)])
            for entry in add(urls: batch) where seen.insert(entry.id).inserted {
                added.append(entry)
            }
            if start + Self.batchSize < files.count {
                // Let the window draw and respond before the next few.
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        if let collection, !added.isEmpty { move(added, to: collection) }
        if starred, !added.isEmpty { setStarred(true, for: added) }
        TextIndexer.shared.index(added)
        return added
    }

    /// The PDFs among `urls`, with each folder replaced by every PDF inside
    /// it, subfolders included, in name order. Hidden files and the insides
    /// of packages (like apps) are skipped.
    nonisolated static func pdfFiles(in urls: [URL]) -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()
        func include(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path(percentEncoded: false)).inserted { files.append(url) }
        }
        for url in urls {
            if isFolder(url) {
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                var found: [URL] = []
                for case let file as URL in enumerator where isPDF(file) {
                    found.append(file)
                }
                found.sort { $0.path(percentEncoded: false).localizedStandardCompare($1.path(percentEncoded: false)) == .orderedAscending }
                found.forEach(include)
            } else if isPDF(url) {
                include(url)
            }
        }
        return files
    }

    nonisolated static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) ?? false
    }

    /// A folder, not a package that looks like a file in Finder.
    nonisolated static func isFolder(_ url: URL) -> Bool {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return values.isDirectory == true && values.isPackage != true
    }

    /// A highlight in the library, found by its ID.
    func highlight(id: UUID) -> HighlightRecord? {
        let descriptor = FetchDescriptor<HighlightRecord>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }
}
