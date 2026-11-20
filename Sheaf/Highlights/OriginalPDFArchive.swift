import Foundation

/// Keeps a copy of a PDF as it was before Sheaf first wrote highlights into
/// it, in Application Support/Original PDFs, so the file can be brought back
/// if a save ever goes wrong.
///
/// Each PDF gets a folder named after its library entry, so it's copied
/// once, even after the file is moved or renamed. Very large files aren't
/// copied, and when the copies add up to too much the oldest make room.
nonisolated struct OriginalPDFArchive: Sendable {
    /// The Original PDFs folder.
    let folder: URL
    /// The library entry of the PDF this copy is for.
    let pdfID: UUID
    var maxFileSize = 300_000_000
    var maxTotalSize = 2_000_000_000

    /// Application Support/Original PDFs, in Sheaf's own storage.
    static var standardFolder: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Original PDFs", directoryHint: .isDirectory)
    }

    private var slot: URL { folder.appending(path: pdfID.uuidString, directoryHint: .isDirectory) }

    var hasCopy: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: slot.path(percentEncoded: false))) ?? []
        return files.contains { !$0.hasPrefix(".") }
    }

    /// Keeps `data` as the original of this PDF, unless a copy is kept already.
    func keepCopy(of data: Data, fileName: String) {
        guard data.count <= maxFileSize, !hasCopy else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
            try data.write(to: slot.appending(path: fileName), options: .atomic)
        } catch {
            NSLog("Sheaf: couldn\u{2019}t keep a copy of \(fileName) before saving: \(error)")
            try? fileManager.removeItem(at: slot)
            return
        }
        makeRoom()
    }

    /// Deletes the oldest copies (never this one) until all fit in `maxTotalSize`.
    private func makeRoom() {
        let fileManager = FileManager.default
        let slots = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        var copies = slots.map { slot in
            (url: slot, created: (try? slot.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, size: Self.size(of: slot))
        }
        var total = copies.reduce(0) { $0 + $1.size }
        copies.sort { $0.created < $1.created }
        for copy in copies where total > maxTotalSize && copy.url.lastPathComponent != pdfID.uuidString {
            try? fileManager.removeItem(at: copy.url)
            total -= copy.size
        }
    }

    private static func size(of folder: URL) -> Int {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}
