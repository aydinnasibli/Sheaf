import Foundation
import Testing
@testable import Sheaf

@MainActor
struct ReadingPositionStoreTests {
    /// Runs `body` with a throwaway preferences domain, so tests never touch real settings.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "SheafTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private let book = URL(filePath: "/Users/test/Books/book.pdf")
    private let paper = URL(filePath: "/Users/test/Papers/paper.pdf")

    @Test func remembersThePageForEachFile() {
        withDefaults { defaults in
            let store = ReadingPositionStore(defaults: defaults)
            store.save(pageIndex: 41, for: book)
            store.save(pageIndex: 3, for: paper)

            #expect(store.pageIndex(for: book) == 41)
            #expect(store.pageIndex(for: paper) == 3)
        }
    }

    @Test func latestSaveWins() {
        withDefaults { defaults in
            let store = ReadingPositionStore(defaults: defaults)
            store.save(pageIndex: 10, for: book)
            store.save(pageIndex: 12, for: book)

            #expect(store.pageIndex(for: book) == 12)
        }
    }

    @Test func unknownFileHasNoPosition() {
        withDefaults { defaults in
            #expect(ReadingPositionStore(defaults: defaults).pageIndex(for: book) == nil)
        }
    }

    @Test func forgetsTheLeastRecentlyReadFilesBeyondTheLimit() {
        withDefaults { defaults in
            let store = ReadingPositionStore(defaults: defaults, limit: 2)
            let third = URL(filePath: "/Users/test/third.pdf")
            let start = Date(timeIntervalSince1970: 1_000_000)

            store.save(pageIndex: 1, for: book, now: start)
            store.save(pageIndex: 2, for: paper, now: start + 60)
            store.save(pageIndex: 3, for: third, now: start + 120)

            #expect(store.pageIndex(for: book) == nil)
            #expect(store.pageIndex(for: paper) == 2)
            #expect(store.pageIndex(for: third) == 3)
        }
    }

    @Test func persistsAcrossStoreInstances() {
        withDefaults { defaults in
            ReadingPositionStore(defaults: defaults).save(pageIndex: 7, for: book)
            #expect(ReadingPositionStore(defaults: defaults).pageIndex(for: book) == 7)
        }
    }
}
