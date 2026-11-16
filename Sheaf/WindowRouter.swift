import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens PDFs as reader tabs, from anywhere in the app: the library, the
/// File > Open panel, and Finder ("Open With", double-click, drag to Dock).
final class WindowRouter {
    static let shared = WindowRouter()

    var library: LibraryStore?
    private var openWindowAction: OpenWindowAction?
    private var pendingEntries: [UUID] = []
    private var pendingURLs: [URL] = []

    /// Called by each window as it appears, so the router can open windows.
    /// Requests that arrive before any window exists wait until then.
    func attach(_ action: OpenWindowAction) {
        openWindowAction = action
        flush()
    }

    func open(_ entry: LibraryEntry) {
        pendingEntries.append(entry.id)
        flush()
    }

    /// Adds files to the library (if new) and opens each in a tab.
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
        guard let library, let openWindow = openWindowAction else { return }
        // Take the queues before opening anything: a new tab calls `attach`,
        // which flushes again, and must not see the same requests.
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls { library.keepAccess(to: url) }
        let ids = pendingEntries + library.add(urls: urls).map(\.id)
        pendingEntries.removeAll()

        var opened = Set<UUID>()
        for id in ids where opened.insert(id).inserted {
            openWindow(id: "reader", value: id)
        }
    }
}

/// Receives PDFs opened from Finder.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        WindowRouter.shared.open(urls: urls.filter(\.isFileURL))
    }
}
