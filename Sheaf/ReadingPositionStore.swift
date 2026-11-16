import Foundation

/// Remembers the last page read in each PDF, keyed by the file's location.
///
/// Moving or renaming a file forgets its position. Only the most recent
/// `limit` files are kept so the stored list doesn't grow forever.
struct ReadingPositionStore {
    static let shared = ReadingPositionStore(defaults: .standard)

    private struct Entry: Codable {
        var page: Int
        var lastRead: Date
    }

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    init(defaults: UserDefaults, key: String = "readingPositions", limit: Int = 500) {
        self.defaults = defaults
        self.key = key
        self.limit = limit
    }

    /// The saved 0-based page index, if this file has been opened before.
    func pageIndex(for fileURL: URL) -> Int? {
        entries()[Self.storageKey(for: fileURL)]?.page
    }

    func save(pageIndex: Int, for fileURL: URL, now: Date = .now) {
        var entries = entries()
        entries[Self.storageKey(for: fileURL)] = Entry(page: pageIndex, lastRead: now)
        if entries.count > limit {
            let oldest = entries.sorted { $0.value.lastRead < $1.value.lastRead }.prefix(entries.count - limit)
            for (path, _) in oldest {
                entries[path] = nil
            }
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    private func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    private static func storageKey(for fileURL: URL) -> String {
        fileURL.standardizedFileURL.path(percentEncoded: false)
    }
}
