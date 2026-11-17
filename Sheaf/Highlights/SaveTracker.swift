import AppKit
import PDFKit

/// Keeps track of saves in progress, so quitting can wait for them.
final class SaveTracker {
    static let shared = SaveTracker()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    var isSaving: Bool { !tasks.isEmpty }

    func track(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks[id] = task
        Task { [weak self] in
            await task.value
            self?.tasks[id] = nil
        }
    }

    func waitForAll() async {
        while !tasks.isEmpty {
            for task in Array(tasks.values) {
                await task.value
            }
            // Let finished tasks remove themselves before checking again.
            await Task.yield()
        }
    }
}

extension Notification.Name {
    /// Posted when the app is about to quit: readers start any pending save now.
    static let sheafFlushSaves = Notification.Name("SheafFlushSaves")
}
