import Foundation

/// Copies the library's files aside each time Sheaf opens, before it touches
/// them, so years of highlights and notes can be brought back if the library
/// is ever damaged. The newest copies are kept in Application Support/Library
/// Backups, one folder per launch.
enum LibraryBackup {
    static let keptCount = 5

    /// Library Backups, next to the library itself.
    static func folder(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: "Library Backups", directoryHint: .isDirectory)
    }

    /// The library's files: the store, its -wal and -shm journals (recent
    /// changes may be only there), and the hidden folder where SwiftData
    /// keeps large values such as covers.
    static func files(of storeURL: URL) -> [URL] {
        let folder = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        let support = ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT"
        return [name, "\(name)-wal", "\(name)-shm", support]
            .map { folder.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Copies the library into a new folder in `backups`, named after the
    /// date and time. Returns the folder, or nil if there was no library yet
    /// or it couldn't be copied (Sheaf opens anyway).
    @discardableResult
    static func backUp(storeURL: URL, into backups: URL? = nil, now: Date = .now) -> URL? {
        let sources = files(of: storeURL)
        guard !sources.isEmpty else { return nil }
        let fileManager = FileManager.default
        let backups = backups ?? folder(for: storeURL)
        var destination = backups.appending(path: folderName(for: now), directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            destination = backups.appending(path: "\(folderName(for: now)) \(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in sources {
                try fileManager.copyItem(at: source, to: destination.appending(path: source.lastPathComponent))
            }
            return destination
        } catch {
            NSLog("Sheaf: couldn\u{2019}t back up the library: \(error)")
            try? fileManager.removeItem(at: destination)
            return nil
        }
    }

    /// Deletes all but the newest `count` backups.
    static func prune(_ backups: URL, keeping count: Int = keptCount) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        // Folder names start with the date and time, so they sort oldest first.
        let sorted = folders.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for folder in sorted.dropLast(count) {
            try? fileManager.removeItem(at: folder)
        }
    }

    /// "2026-11-20 14.03.22": sorts by date, and has no characters Finder
    /// shows oddly.
    static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date)
    }
}
