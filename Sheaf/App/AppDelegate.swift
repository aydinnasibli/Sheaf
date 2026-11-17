import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Receives PDFs opened from Finder, and makes quitting wait for saves.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Control-Tab / Control-Shift-Tab switch between the library and open
        // PDFs. macOS normally uses Control-Tab to move focus between
        // controls, so catch it before that happens.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] else { return event }
            MainActor.assumeIsolated {
                guard let workspace = WindowRouter.shared.workspace, !workspace.documents.isEmpty else { return }
                if modifiers.contains(.shift) { workspace.selectPrevious() } else { workspace.selectNext() }
            }
            return nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WindowRouter.shared.open(urls: urls.filter(\.isFileURL))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Start any save that was waiting for a pause in highlighting…
        NotificationCenter.default.post(name: .sheafFlushSaves, object: nil)
        guard SaveTracker.shared.isSaving else { return .terminateNow }
        // …and quit once highlights are safely written into the files.
        Task {
            await SaveTracker.shared.waitForAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
