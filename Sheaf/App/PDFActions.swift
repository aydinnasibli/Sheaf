import AppKit
import SwiftData
import UniformTypeIdentifiers

extension LibraryEntry {
    /// False once the PDF has been removed from the library.
    var isInLibrary: Bool { modelContext != nil && !isDeleted }
}

extension UTType {
    /// Marks a PDF dragged from the library's list (declared in Info.plist),
    /// so the list doesn't offer to add it to the library again.
    static let sheafLibraryPDF = UTType(exportedAs: "com.aydinnasibli.sheaf.library-pdf")
}

/// What the File menu, the library's context menu and the reader's title
/// menu do to PDFs: open (here or in a new window), show in Finder, share,
/// star, collections, rename and remove from the library. Each acts on the
/// PDFs passed in; the menu bar passes `commandTargets(in:)`.
extension Workspace {
    /// The PDFs the menu bar's PDF commands act on in the main window: the
    /// one on screen, or the ones selected in the library's list (newest first).
    var commandTargets: [LibraryEntry] { commandTargets(in: mainWindow) }

    /// What the menu bar's PDF commands act on in a window: the PDF on
    /// screen there, or in the main window's library, the selected PDFs.
    func commandTargets(in window: ReaderWindow) -> [LibraryEntry] {
        if let document = document(in: window) {
            return document.entry.isInLibrary ? [document.entry] : []
        }
        guard window.isMain, libraryScope.showsPDFs else { return [] }
        return librarySelection.compactMap(library.entry(id:)).sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    // MARK: Opening

    /// Opens PDFs; the last one stays on screen. A PDF whose file can't be
    /// found asks what to do instead.
    func openPDFs(_ entries: [LibraryEntry]) {
        for entry in entries where canOpen(entry) {
            open(entry)
        }
    }

    /// Opens each PDF in its own window, to read side by side. A PDF whose
    /// file can't be found asks what to do instead.
    func openPDFsInNewWindows(_ entries: [LibraryEntry]) {
        for entry in entries where canOpen(entry) {
            openInNewWindow(entry)
        }
    }

    /// Whether the PDF's file can be found; if it can't, asks about it.
    private func canOpen(_ entry: LibraryEntry) -> Bool {
        guard library.resolveFile(for: entry) != nil else {
            missingFileRequest = entry.id
            return false
        }
        return true
    }

    // MARK: Finder and sharing

    func showInFinder(_ entries: [LibraryEntry]) {
        let urls = files(of: entries)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The share picker (AirDrop, Mail, Messages…) for the PDFs' files,
    /// pointing at `view`, or at the reader's title or the pointer.
    func share(_ entries: [LibraryEntry], from view: NSView? = nil) {
        let urls = files(of: entries)
        guard !urls.isEmpty else { return }
        SharePicker.show(urls, from: view)
    }

    /// Quick Look of the PDFs (Space in the list, or ⌘Y), or closes it if
    /// it's open. Its arrows step through all of them.
    func toggleQuickLook(_ entries: [LibraryEntry]) {
        guard quickLookFile == nil else {
            quickLookFile = nil
            return
        }
        let urls = files(of: entries)
        guard let first = urls.first else { return }
        quickLookFiles = urls
        quickLookFile = first
    }

    /// The files that can be found; if none can, asks about the first PDF.
    private func files(of entries: [LibraryEntry]) -> [URL] {
        let urls = entries.compactMap(library.resolveFile(for:))
        if urls.isEmpty, let first = entries.first {
            missingFileRequest = first.id
        }
        return urls
    }

    /// What a PDF carries when dragged out of the list: its file, for
    /// Finder, Mail and the left panel's collections, and a mark that it
    /// came from the list. `nil` if its file can't be found.
    func dragItem(for entry: LibraryEntry) -> NSItemProvider? {
        guard let url = library.resolveFile(for: entry) else { return nil }
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        let id = Data(entry.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.sheafLibraryPDF.identifier, visibility: .all) { completion in
            completion(id, nil)
            return nil
        }
        return provider
    }

    // MARK: Star and collections

    func setStarred(_ starred: Bool, for entries: [LibraryEntry]) {
        library.setStarred(starred, for: entries)
    }

    func move(_ entries: [LibraryEntry], to collection: PDFCollection?) {
        library.move(entries, to: collection)
    }

    /// Asks for a new collection's name (see `PDFActionAlerts`); the PDFs go in it.
    func requestNewCollection(for entries: [LibraryEntry] = []) {
        newCollectionRequest = entries.map(\.id)
    }

    /// Makes a collection with the name she gave, and puts the PDFs in it.
    @discardableResult
    func createCollection(named name: String, with ids: [UUID]) -> PDFCollection {
        let collection = library.createCollection(named: name)
        let entries = ids.compactMap(library.entry(id:))
        if !entries.isEmpty { library.move(entries, to: collection) }
        return collection
    }

    /// Deletes a collection; its PDFs stay in the library. Undo brings it
    /// back as it was, with its PDFs.
    func deleteCollection(_ id: UUID, undoManager: UndoManager?) {
        guard let collection = library.collection(id: id) else { return }
        if libraryScope == .collection(id) { libraryScope = .all }
        let deleted = library.delete(collection)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.restoreCollection(deleted, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Collection")
    }

    /// Undo of `deleteCollection`.
    private func restoreCollection(_ deleted: DeletedCollection, undoManager: UndoManager?) {
        guard library.restore(deleted) != nil else { return }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.deleteCollection(deleted.id, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Collection")
    }

    // MARK: Renaming

    /// Asks for a new title (see `PDFActionAlerts`).
    func requestRename(_ entry: LibraryEntry) {
        renameRequest = entry.id
    }

    /// Changes the title shown in Sheaf; the file keeps its name. Open
    /// readers, the window title and Spotlight follow. Undo puts the old
    /// title back.
    func rename(_ id: UUID, to title: String, undoManager: UndoManager?) {
        guard let entry = library.entry(id: id) else { return }
        let old = entry.title
        guard library.rename(entry, to: title) else { return }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.rename(id, to: old, undoManager: undoManager)
        }
        undoManager?.setActionName("Rename")
    }

    // MARK: Removing

    /// Asks before removing PDFs from the library (see `PDFActionAlerts`).
    func requestRemoval(of entries: [LibraryEntry]) {
        guard !entries.isEmpty else { return }
        removalRequest = entries.map(\.id)
    }

    /// Removes PDFs from the library, with their highlights, notes and
    /// bookmarks in Sheaf. Open ones are closed first, so nothing is saved
    /// for a PDF that's gone. Undo puts everything back.
    func remove(_ ids: [UUID], undoManager: UndoManager?) {
        let entries = ids.compactMap(library.entry(id:))
        guard !entries.isEmpty else { return }
        // In any window; a PDF's own window closes with it.
        for entry in entries where isOpen(entry.id) {
            close(entry.id)
        }
        librarySelection.subtract(entries.map(\.id))
        let removed = library.remove(entries)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.restore(removed, undoManager: undoManager)
        }
        undoManager?.setActionName("Remove from Library")
    }

    /// Undo of `remove`: the PDFs come back, selected.
    private func restore(_ removed: [RemovedPDF], undoManager: UndoManager?) {
        let entries = library.restore(removed)
        librarySelection = Set(entries.map(\.id))
        let ids = entries.map(\.id)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.remove(ids, undoManager: undoManager)
        }
        undoManager?.setActionName("Remove from Library")
    }
}
