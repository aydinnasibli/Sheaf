import Foundation
import Synchronization
@testable import Sheaf

/// iCloud Drive for tests: files are on this Mac unless a test says they
/// aren't. Records what was asked, and on which thread.
final class FakeCloud: CloudFiles {
    private struct State {
        var statuses: [String: CloudStatus] = [:]
        var downloadsStarted: [String] = []
        var askedOnMainThread = false
        var asked = 0
    }

    private let state = Mutex(State())

    /// Every file not given a status here is on this Mac.
    func setStatus(_ status: CloudStatus, of url: URL) {
        state.withLock { $0.statuses[Self.key(url)] = status }
    }

    /// Files whose download was started.
    var downloadsStarted: [String] { state.withLock { $0.downloadsStarted } }
    /// Whether any question came from the main thread.
    var askedOnMainThread: Bool { state.withLock { $0.askedOnMainThread } }
    var questionsAsked: Int { state.withLock { $0.asked } }

    func status(of url: URL) -> CloudStatus {
        let isMain = Thread.isMainThread
        return state.withLock { state in
            state.asked += 1
            if isMain { state.askedOnMainThread = true }
            return state.statuses[Self.key(url)] ?? .local
        }
    }

    func startDownloading(_ url: URL) {
        state.withLock { $0.downloadsStarted.append(Self.key(url)) }
    }

    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }
}
