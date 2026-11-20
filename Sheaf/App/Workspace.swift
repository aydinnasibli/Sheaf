import AppKit
import Observation
import PDFKit
import SwiftUI

/// Sheaf's main window shows either the library or one open PDF. Several
/// PDFs can be open at once; they're listed under "Open now" in the library,
/// and Control-Tab switches between them. A PDF can also have its own
/// window, to read two side by side; it's then in that window only.
@Observable
final class Workspace {
    /// The PDFs in the main window, listed under "Open now".
    private(set) var documents: [OpenDocument] = []
    /// The PDFs in their own windows (see `PDFWindow`), in the order they
    /// were opened. Each is in one window only, so not in `documents`.
    private(set) var windowedDocuments: [OpenDocument] = []
    /// The PDF on screen in the main window, or `nil` for the library.
    private(set) var selectedID: UUID? {
        didSet {
            if selectedID == nil { isFocusMode = false }
            // Each PDF loads the first time it's shown, so the ones reopened
            // at launch don't all load at once.
            selectedDocument?.loadIfNeeded()
        }
    }
    /// Incremented by Find / Search Library (⌘F, ⌘K) to focus the library's search field.
    var librarySearchRequest = 0
    /// The main window: its side panels and focus mode. Each PDF window has its own.
    let mainWindow = ReaderWindow(kind: .main)
    /// Focus mode in the main window: only the page, full screen, with the
    /// side panels hidden. Going back to the library ends it.
    var isFocusMode: Bool {
        get { mainWindow.isFocusMode }
        set { mainWindow.isFocusMode = newValue }
    }
    /// The reading window in front most recently. The questions the PDF
    /// commands ask appear there (see `alertWindow`), and Control-Tab
    /// switches PDFs only in the main window.
    @ObservationIgnored var frontWindow = ReaderWindow.Kind.main
    /// The window the question being asked appears in: the one that was in
    /// front when it was asked.
    private(set) var alertWindow = ReaderWindow.Kind.main
    /// Brings a reading window to the front, opening it if needed. Set by
    /// `WindowRouter`; in tests it does nothing.
    @ObservationIgnored var showWindow: (ReaderWindow.Kind) -> Void = { _ in }
    /// Set while Sheaf quits. PDF windows that close then keep their PDFs
    /// open, so they come back the next time.
    @ObservationIgnored var isQuitting = false
    /// What the library shows, chosen in its left panel. Kept here so the
    /// library comes back to it after reading a PDF.
    var libraryScope = LibraryScope.all
    /// The review in progress, kept while a PDF is open so it can go on after.
    var review: ReviewDeck?

    /// The PDFs selected in the library's list. Kept here so the menu bar
    /// can act on them, and so they're still selected after reading a PDF.
    var librarySelection = Set<UUID>()
    /// Whether the library's list has keyboard focus, so ⌘⌫ removes the
    /// selected PDFs there and still deletes text in a text field.
    var isLibraryListFocused = false
    /// PDFs waiting for the user to confirm removing them (see `PDFActionAlerts`).
    var removalRequest: [UUID]? {
        didSet { if removalRequest != nil { alertWindow = frontWindow } }
    }
    /// The PDF being renamed (see `PDFActionAlerts`).
    var renameRequest: UUID? {
        didSet { if renameRequest != nil { alertWindow = frontWindow } }
    }
    /// A new collection waiting for its name, with the PDFs to put in it
    /// (none from the left panel's New Collection; see `PDFActionAlerts`).
    var newCollectionRequest: [UUID]? {
        didSet { if newCollectionRequest != nil { alertWindow = frontWindow } }
    }
    /// A PDF whose file couldn't be found when opening or sharing it (see `PDFActionAlerts`).
    var missingFileRequest: UUID? {
        didSet { if missingFileRequest != nil { alertWindow = frontWindow } }
    }
    /// The files Quick Look is showing from the library's list, and the one
    /// on screen (`nil` when it's closed).
    var quickLookFiles: [URL] = []
    var quickLookFile: URL?

    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored private let preferences: UserDefaults
    private static let openKey = "openDocuments"
    private static let selectedKey = "selectedDocument"
    private static let windowedKey = "windowedDocuments"

    init(library: LibraryStore, preferences: UserDefaults = .standard) {
        self.library = library
        self.preferences = preferences
    }

    var selectedDocument: OpenDocument? {
        documents.first { $0.id == selectedID }
    }

    var isShowingLibrary: Bool { selectedDocument == nil }

    /// Every open PDF, in the main window and in their own windows.
    var allDocuments: [OpenDocument] { documents + windowedDocuments }

    func windowedDocument(id: UUID) -> OpenDocument? {
        windowedDocuments.first { $0.id == id }
    }

    /// Whether the PDF is open, in any window.
    func isOpen(_ id: UUID) -> Bool {
        allDocuments.contains { $0.id == id }
    }

    /// The PDF on screen in a window: the main window's, or a PDF window's own.
    func document(in window: ReaderWindow) -> OpenDocument? {
        switch window.kind {
        case .main: selectedDocument
        case .pdf(let id): windowedDocument(id: id)
        }
    }

    /// Opens a PDF (or switches to it if it's already open), optionally
    /// scrolling to one of its highlights. It opens in the main window,
    /// unless it has its own window: then that window comes to the front.
    @discardableResult
    func open(_ entry: LibraryEntry, at highlight: HighlightRecord? = nil) -> OpenDocument {
        if let document = windowedDocument(id: entry.id) {
            if let highlight { document.pendingHighlightID = highlight.id }
            showWindow(.pdf(entry.id))
            return document
        }
        let document = documents.first { $0.id == entry.id } ?? {
            let new = OpenDocument(entry: entry, library: library)
            documents.append(new)
            return new
        }()
        if let highlight {
            document.pendingHighlightID = highlight.id
        }
        selectedID = document.id
        persist()
        showWindow(.main)
        return document
    }

    /// Opens a PDF at a page (0-based), as when clicking a search match.
    func open(_ entry: LibraryEntry, atPage pageIndex: Int) {
        open(entry).pendingPageIndex = pageIndex
    }

    // MARK: PDFs in their own windows

    /// Opens a PDF in its own window, to read it beside another. A PDF
    /// that's open in the main window moves out of it, and out of its
    /// "Open now" list, keeping its place; one already in its own window
    /// comes to the front.
    func openInNewWindow(_ entry: LibraryEntry) {
        if windowedDocument(id: entry.id) == nil {
            windowedDocuments.append(takeFromMainWindow(entry.id) ?? OpenDocument(entry: entry, library: library))
            persist()
        }
        showWindow(.pdf(entry.id))
    }

    /// Puts a PDF from its own window back in the main window, on screen
    /// there. Its own window closes.
    func moveToMainWindow(_ id: UUID) {
        guard let index = windowedDocuments.firstIndex(where: { $0.id == id }) else { return }
        let document = windowedDocuments.remove(at: index)
        // Saves, and leaves Undo in the window it's leaving with nothing for it.
        document.model?.suspend()
        documents.append(document)
        selectedID = id
        persist()
        showWindow(.main)
    }

    /// Called by a PDF's window as it appears, also when macOS reopens it
    /// at launch: the PDF loads, moving out of the main window's list if
    /// `restore()` put it there. Returns false if the PDF is no longer in
    /// the library, and the window closes.
    func ownWindowDidAppear(_ id: UUID) -> Bool {
        if windowedDocument(id: id) == nil {
            if let document = takeFromMainWindow(id) {
                windowedDocuments.append(document)
            } else if let entry = library.entry(id: id) {
                windowedDocuments.append(OpenDocument(entry: entry, library: library))
            } else {
                return false
            }
            persist()
        }
        windowedDocument(id: id)?.loadIfNeeded()
        return true
    }

    /// Called when a PDF's window closes: the PDF closes too, saving first,
    /// as closing it in the main window does. Not while Sheaf quits, so the
    /// window and its PDF come back the next time.
    func ownWindowDidClose(_ id: UUID) {
        guard !isQuitting, windowedDocument(id: id) != nil else { return }
        close(id)
    }

    /// Takes a PDF out of the main window, which goes back to the library
    /// if it was on screen.
    private func takeFromMainWindow(_ id: UUID) -> OpenDocument? {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return nil }
        if selectedID == id { selectedID = nil }
        let document = documents.remove(at: index)
        // Saves, and leaves Undo in the main window with nothing for it.
        document.model?.suspend()
        return document
    }

    func showLibrary() {
        selectedID = nil
        persist()
    }

    func select(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
    }

    /// Closes a PDF, saving first. If it was on screen in the main window,
    /// the library comes back; if it was in its own window, that closes.
    func close(_ id: UUID) {
        if let index = documents.firstIndex(where: { $0.id == id }) {
            documents[index].close()
            documents.remove(at: index)
            if selectedID == id { selectedID = nil }
        } else if let index = windowedDocuments.firstIndex(where: { $0.id == id }) {
            windowedDocuments[index].close()
            windowedDocuments.remove(at: index)
            if frontWindow == .pdf(id) { frontWindow = .main }
        } else {
            return
        }
        persist()
    }

    /// Cycles library → open PDFs → library (Control-Tab).
    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    private func step(by offset: Int) {
        let order: [UUID?] = [nil] + documents.map(\.id)
        let current = order.firstIndex(of: selectedID) ?? 0
        selectedID = order[(current + offset + order.count) % order.count]
        persist()
    }

    // MARK: Remembering open PDFs between launches

    /// Reopens the PDFs that were open when Sheaf last quit. Only the one on
    /// screen loads now; the others load when they're shown.
    ///
    /// PDFs that were in their own windows join the main window's list for
    /// now. macOS reopens their windows, and each window takes its PDF back
    /// (`ownWindowDidAppear`); any it doesn't reopen (if the Mac is set to
    /// close windows when quitting, say) stay under "Open now".
    func restore() {
        let saved = (preferences.stringArray(forKey: Self.openKey) ?? []) + (preferences.stringArray(forKey: Self.windowedKey) ?? [])
        for id in saved.compactMap(UUID.init(uuidString:)) where !isOpen(id) {
            if let entry = library.entry(id: id) {
                documents.append(OpenDocument(entry: entry, library: library))
            }
        }
        if let selected = preferences.string(forKey: Self.selectedKey).flatMap(UUID.init(uuidString:)),
           documents.contains(where: { $0.id == selected }) {
            selectedID = selected
        }
    }

    private func persist() {
        preferences.set(documents.map(\.id.uuidString), forKey: Self.openKey)
        preferences.set(selectedID?.uuidString, forKey: Self.selectedKey)
        preferences.set(windowedDocuments.map(\.id.uuidString), forKey: Self.windowedKey)
    }
}
