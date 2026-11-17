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
