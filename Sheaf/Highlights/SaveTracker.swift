import AppKit
import PDFKit

/// Keeps track of saves in progress, so quitting can wait for them.
final class SaveTracker {
    static let shared = SaveTracker()

    private var tasks: [UUID: (task: Task<Void, Never>, fileName: String)] = [:]

    var isSaving: Bool { !tasks.isEmpty }

    /// The files being saved, for the alert when quitting takes too long.
    var fileNames: [String] { Set(tasks.values.map(\.fileName)).filter { !$0.isEmpty }.sorted() }

    func track(_ task: Task<Void, Never>, fileName: String = "") {
        let id = UUID()
        tasks[id] = (task, fileName)
        Task { [weak self] in
            await task.value
            self?.tasks[id] = nil
        }
    }

    func waitForAll() async {
        while !tasks.isEmpty {
            for (task, _) in Array(tasks.values) {
                await task.value
            }
            // Let finished tasks remove themselves before checking again.
            await Task.yield()
        }
    }

    /// Waits for the saves to finish, but no longer than `timeout`. Returns
    /// whether they all finished.
    func waitForAll(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isSaving {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}

extension Notification.Name {
    /// Posted when the app is about to quit: readers start any pending save now.
    static let sheafFlushSaves = Notification.Name("SheafFlushSaves")
}
