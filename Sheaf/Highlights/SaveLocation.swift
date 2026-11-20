import Foundation

/// Where a PDF's highlights are saved: the file found again through its
/// bookmark before each save, so a PDF that's moved or renamed while it's
/// open still saves.
///
/// Finding the file runs with the save, away from the main thread: a
/// bookmark to a file on a network drive can take a while to resolve. It
/// never mounts a drive or asks anything: a drive that's gone makes the
/// save fail, and it's tried again later.
nonisolated struct SaveLocation: Sendable {
    /// The library's security-scoped bookmark for the file, if it has one.
    let bookmark: Data?
    /// Where the file was last seen, for a PDF without a bookmark.
    let path: URL?

    struct Result: Sendable {
        let outcome: PDFHighlightWriter.Outcome
        /// The file saved into, when it was found.
        let url: URL?
        /// A new bookmark for the file, made after a save: the save
        /// replaced the file, which an older bookmark may not follow.
        let bookmark: Data?
    }

    /// Finds the file and writes `highlights` into it (see `PDFHighlightWriter.write`).
    func write(
        _ highlights: [HighlightSnapshot], removing removedIDs: Set<UUID>, keepingOriginalIn archive: OriginalPDFArchive?
    ) -> Result {
        guard let url = resolve() else {
            return Result(outcome: .failed("The file couldn\u{2019}t be found."), url: nil, bookmark: nil)
        }
        // The library keeps access to its files while Sheaf runs; this
        // covers a file found at a new place, for the save.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return Result(outcome: .failed("The file couldn\u{2019}t be found."), url: url, bookmark: nil)
        }
        let outcome = PDFHighlightWriter.write(highlights, removing: removedIDs, to: url, keepingOriginalIn: archive)
        let fresh = outcome == .saved
            ? try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            : nil
        return Result(outcome: outcome, url: url, bookmark: fresh)
    }

    private func resolve() -> URL? {
        guard let bookmark else { return path }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
