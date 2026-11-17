import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens PDFs in Sheaf's window, from anywhere: the library, File > Open,
/// and Finder ("Open With", double-click, dragging onto the Dock icon).
final class WindowRouter {
    static let shared = WindowRouter()

    var library: LibraryStore?
    var workspace: Workspace?
    private var openWindowAction: OpenWindowAction?
    private var pendingURLs: [URL] = []

    /// Called when the window appears, so the router can reopen it later.
    func attach(_ action: OpenWindowAction) {
        openWindowAction = action
        flush()
    }

    /// Shows the window (reopening it if it was closed) with the library.
    func showLibrary() {
        workspace?.showLibrary()
        openWindowAction?(id: "main")
    }

    func open(_ entry: LibraryEntry, at highlight: HighlightRecord? = nil) {
        workspace?.open(entry, at: highlight)
        openWindowAction?(id: "main")
    }

    /// Adds files to the library (if new) and opens them; the last one is shown.
    func open(urls: [URL]) {
        pendingURLs += urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .pdf) ?? false }
        flush()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDFs to open. They\u{2019}ll be added to your library and stay where they are."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls)
        }
    }

    private func flush() {
        guard let library, let workspace, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls { library.keepAccess(to: url) }
        for entry in library.add(urls: urls) {
            workspace.open(entry)
        }
        openWindowAction?(id: "main")
    }
}

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
