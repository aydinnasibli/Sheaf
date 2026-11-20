import CoreData
import Foundation
import SwiftData

/// Copies the library's files aside each time Sheaf opens, before it touches
/// them, so years of highlights and notes can be brought back if the library
/// is ever damaged. They're kept in Application Support/Library Backups, one
/// folder per launch.
///
/// Sheaf may open several times a day (an update relaunches it, too), so
/// keeping only the newest few would let a damaged library push every good
/// copy out within days. Instead it keeps the newest few, the newest of each
/// recent day, and the newest of each recent week: copies from about a month
/// back, whatever happened since. A copy taken just before a new version of
/// Sheaf changed how the library is stored is marked so in its folder's name
/// and kept longer too.
enum LibraryBackup {
    /// The newest backups, kept whatever their age.
    static let keptCount = 5
    /// The most recent days with backups that keep their newest one.
    static let keptDays = 7
    /// The most recent weeks with backups that keep their newest one. With
    /// this week, that reaches back four to five weeks: about a month.
    static let keptWeeks = 6
    /// How many backups from before a library format change are kept.
    static let keptBeforeFormatChange = 3
    /// Added to the folder name of a backup taken just before a library format change.
    static let formatChangeSuffix = " before library update"

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
    /// date and time, and after a format change when the library was saved
    /// in an older format than `models`. Returns the folder, or nil if there
    /// was no library yet or it couldn't be copied (Sheaf opens anyway).
    @discardableResult
    static func backUp(
        storeURL: URL, into backups: URL? = nil, now: Date = .now,
        models: [any PersistentModel.Type] = LibraryStore.models
    ) -> URL? {
        let sources = files(of: storeURL)
        guard !sources.isEmpty else { return nil }
        let fileManager = FileManager.default
        let backups = backups ?? folder(for: storeURL)
        let copy = freeFolder(named: folderName(for: now), in: backups)
        do {
            try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)
            for source in sources {
                try fileManager.copyItem(at: source, to: copy.appending(path: source.lastPathComponent))
            }
        } catch {
            NSLog("Sheaf: couldn\u{2019}t back up the library: \(error)")
            try? fileManager.removeItem(at: copy)
            return nil
        }
        guard formatDiffersInCopy(of: copy.appending(path: storeURL.lastPathComponent), from: models) else { return copy }
        let marked = freeFolder(named: folderName(for: now) + formatChangeSuffix, in: backups)
        guard (try? fileManager.moveItem(at: copy, to: marked)) != nil else { return copy }
        return marked
    }

    /// `formatDiffers` for the library at `storeURL`, checked in a throwaway
    /// copy of it: reading a library touches its journal files, and neither
    /// the library nor its backup should change. (Copies on the Mac's own
    /// drive take no extra space.)
    private static func formatDiffersInCopy(of storeURL: URL, from models: [any PersistentModel.Type]) -> Bool {
        let fileManager = FileManager.default
        guard let scratch = try? fileManager.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: storeURL, create: true
        ) else { return false }
        defer { try? fileManager.removeItem(at: scratch) }
        let name = storeURL.lastPathComponent
        for file in [name, "\(name)-wal", "\(name)-shm"] {
            let source = storeURL.deletingLastPathComponent().appending(path: file)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            guard (try? fileManager.copyItem(at: source, to: scratch.appending(path: file))) != nil else { return false }
        }
        return formatDiffers(storeURL: scratch.appending(path: name), from: models)
    }

    /// Whether the library at `storeURL` was saved by a version of Sheaf
    /// whose models differ from `models`, so opening it will convert it.
    /// False when that can't be told (no library there, say).
    static func formatDiffers(storeURL: URL, from models: [any PersistentModel.Type]) -> Bool {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
                  type: .sqlite, at: storeURL, options: [NSReadOnlyPersistentStoreOption: true]
              ),
              let stored = metadata[NSStoreModelVersionHashesKey] as? [String: Data],
              let model = NSManagedObjectModel.makeManagedObjectModel(for: models)
        else { return false }
        return stored != model.entityVersionHashesByName
    }

    /// Deletes the backups the rules above don't keep. Folders that aren't
    /// backups (their names don't start with a date) are left alone.
    static func prune(_ backups: URL, calendar: Calendar = .current) {
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        let dated = folders.compactMap { folder in date(of: folder.lastPathComponent).map { (folder: folder, date: $0) } }
        let kept = keptBackups(dated.map { (name: $0.folder.lastPathComponent, date: $0.date) }, calendar: calendar)
        for backup in dated where !kept.contains(backup.folder.lastPathComponent) {
            try? fileManager.removeItem(at: backup.folder)
        }
    }

    /// The names of the backups to keep, out of `backups`.
    static func keptBackups(_ backups: [(name: String, date: Date)], calendar: Calendar) -> Set<String> {
        // Newest first; folders from the same second by their number ("… 2").
        let newestFirst = backups.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.name.localizedStandardCompare(b.name) == .orderedDescending
        }
        var kept = Set(newestFirst.prefix(keptCount).map(\.name))
        func keepNewest(per component: Calendar.Component, count: Int) {
            var periods = Set<Date>()
            for backup in newestFirst {
                guard let start = calendar.dateInterval(of: component, for: backup.date)?.start else { continue }
                if periods.contains(start) { continue }
                guard periods.count < count else { break }
                periods.insert(start)
                kept.insert(backup.name)
            }
        }
        keepNewest(per: .day, count: keptDays)
        keepNewest(per: .weekOfYear, count: keptWeeks)
        let beforeChanges = newestFirst.filter { $0.name.contains(formatChangeSuffix) }
        kept.formUnion(beforeChanges.prefix(keptBeforeFormatChange).map(\.name))
        return kept
    }

    /// "2026-11-20 14.03.22": sorts by date, and has no characters Finder
    /// shows oddly.
    static func folderName(for date: Date) -> String {
        formatter.string(from: date)
    }

    /// The date and time a backup's folder name starts with.
    static func date(of folderName: String) -> Date? {
        formatter.date(from: String(folderName.prefix(19)))
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }

    /// `name` in `folder`, or "name 2", "name 3"… if it's taken.
    private static func freeFolder(named name: String, in folder: URL) -> URL {
        var candidate = folder.appending(path: name, directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(name) \(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        return candidate
    }
}
