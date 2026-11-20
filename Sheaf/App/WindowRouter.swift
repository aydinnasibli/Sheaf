import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens PDFs in Sheaf's windows, from anywhere: the library, File > Open,
/// Finder ("Open With", double-click, dragging onto the Dock icon) and
/// Spotlight. A PDF opens in the main window, unless it has its own window:
/// then that window comes to the front.
final class WindowRouter {
    static let shared = WindowRouter()

    var library: LibraryStore?
    var workspace: Workspace? {
        // The workspace asks for its windows through here.
        didSet { workspace?.showWindow = { [weak self] in self?.show($0) } }
    }
    private var openWindowAction: OpenWindowAction?
    private var pendingURLs: [URL] = []

    /// Called when a window appears, so the router can open windows later.
    func attach(_ action: OpenWindowAction) {
        openWindowAction = action
        flush()
    }

    /// Brings a reading window to the front, opening (or reopening) it if
    /// needed. SwiftUI keeps one window per PDF, so asking for a PDF's
    /// window again brings that window forward.
    func show(_ window: ReaderWindow.Kind) {
        switch window {
        case .main: openWindowAction?(id: "main")
        case .pdf(let id): openWindowAction?(id: PDFWindow.sceneID, value: id)
        }
    }

    /// Shows the main window (reopening it if it was closed) with the library.
    func showLibrary() {
        workspace?.showLibrary()
        show(.main)
    }

    /// The workspace brings the PDF's window to the front.
    func open(_ entry: LibraryEntry, at highlight: HighlightRecord? = nil) {
        workspace?.open(entry, at: highlight)
    }

    /// Opens a PDF at a page (0-based), as when clicking a search match.
    func open(_ entry: LibraryEntry, atPage pageIndex: Int) {
        workspace?.open(entry, atPage: pageIndex)
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
        // Each comes to the front in its window.
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
        if opened.isEmpty { show(.main) }
    }
}
