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

    /// Opens a PDF at a page (0-based), as when clicking a search match.
    func open(_ entry: LibraryEntry, atPage pageIndex: Int) {
        workspace?.open(entry, atPage: pageIndex)
        openWindowAction?(id: "main")
    }

    /// Adds files to the library (if new) and opens them; the last one is shown.
    /// Folders add every PDF inside them to the library, without opening them.
    func open(urls: [URL]) {
        pendingURLs += urls.filter { LibraryStore.isPDF($0) || LibraryStore.isFolder($0) }
        flush()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose PDFs to open, or folders to add every PDF inside them. They\u{2019}ll be added to your library and stay where they are."
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
        let folders = urls.filter(LibraryStore.isFolder)
        let opened = library.add(urls: urls.filter { !folders.contains($0) })
        for entry in opened {
            workspace.open(entry)
        }
        TextIndexer.shared.index(opened)
        if !folders.isEmpty {
            // A folder can hold dozens of PDFs: add them all, open none, and
            // show the whole library, where the new ones are at the top.
            Task { _ = await library.addFiles(folders) }
            if opened.isEmpty {
                workspace.libraryScope = .all
                workspace.showLibrary()
            }
        }
        openWindowAction?(id: "main")
    }
}
