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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
            let handled = MainActor.assumeIsolated {
                if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift] {
                    return Self.switchOpenPDF(backward: modifiers.contains(.shift))
                }
                if modifiers == .command, event.charactersIgnoringModifiers == "=" {
                    return Self.zoomIn()
                }
                return false
            }
            return handled ? nil : event
        }
        if WindowRouter.shared.library?.isTemporaryLibrary == true {
            // Once the window is up.
            Task { SafetyAlerts.showLibraryCouldNotOpen() }
        }
    }

    /// Control-Tab / Control-Shift-Tab switch between the library and open
    /// PDFs in the main window. macOS normally uses Control-Tab to move
    /// focus between controls, so it's caught before that happens. Returns
    /// false to leave it to macOS: in a PDF's own window it switches tabs
    /// once windows are merged, and in Help or Settings it moves the focus.
    private static func switchOpenPDF(backward: Bool) -> Bool {
        guard let workspace = WindowRouter.shared.workspace,
              FrontReaderWindow.shared.window?.isMain == true
        else { return false }
        if !workspace.documents.isEmpty {
            if backward { workspace.selectPrevious() } else { workspace.selectNext() }
        }
        return true
    }

    /// ⌘= zooms in, like View › Zoom In (⌘+), which on most keyboards
    /// needs Shift. A menu item can have only one shortcut, so it's here.
    private static func zoomIn() -> Bool {
        guard let window = FrontReaderWindow.shared.window,
              let reader = WindowRouter.shared.workspace?.document(in: window)?.model
        else { return false }
        reader.zoomIn()
        return true
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
