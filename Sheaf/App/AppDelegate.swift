import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Receives PDFs opened from Finder and highlights picked in Spotlight,
/// and makes quitting wait for saves.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugSnapshot.start()
        #endif
        // Control-Tab / Control-Shift-Tab switch between the library and open
        // PDFs in the main window. macOS normally uses Control-Tab to move
        // focus between controls, so catch it before that happens.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] else { return event }
            let handled = MainActor.assumeIsolated {
                guard let workspace = WindowRouter.shared.workspace else { return false }
                // In a PDF's own window it's left to macOS, which switches
                // tabs with it once windows are merged.
                guard workspace.frontWindow == .main else { return false }
                if !workspace.documents.isEmpty {
                    if modifiers.contains(.shift) { workspace.selectPrevious() } else { workspace.selectNext() }
                }
                return true
            }
            return handled ? nil : event
        }
        if WindowRouter.shared.library?.isTemporaryLibrary == true {
            // Once the window is up.
            Task { SafetyAlerts.showLibraryCouldNotOpen() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WindowRouter.shared.open(urls: urls.filter(\.isFileURL))
    }

    /// A highlight picked in Spotlight: opens its PDF there.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        SpotlightResult.open(userActivity)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Start any save that was waiting for a pause in highlighting…
        NotificationCenter.default.post(name: .sheafFlushSaves, object: nil)
        guard SaveTracker.shared.isSaving else {
            WindowRouter.shared.workspace?.isQuitting = true
            return .terminateNow
        }
        // …and quit once highlights are safely written into the files. A
        // save that takes longer than that (a slow or disconnected drive)
        // shouldn't keep Sheaf open: ask instead.
        Task {
            let finished = await SaveTracker.shared.waitForAll(timeout: .seconds(10))
            let quit = finished || SafetyAlerts.confirmQuitWhileSaving(fileNames: SaveTracker.shared.fileNames)
            // PDF windows closing as Sheaf quits keep their PDFs for next time.
            WindowRouter.shared.workspace?.isQuitting = quit
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }
}
