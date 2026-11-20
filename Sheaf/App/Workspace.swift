import AppKit
import Observation
import PDFKit
import SwiftUI

/// Sheaf's one window shows either the library or one open PDF. Several
/// PDFs can be open at once; they're listed under "Open now" in the library,
/// and Control-Tab switches between them.
@Observable
final class Workspace {
    private(set) var documents: [OpenDocument] = []
    /// The PDF on screen, or `nil` for the library.
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
    /// Focus mode: only the page, full screen, with the side panels hidden.
    /// Going back to the library ends it.
    var isFocusMode = false
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
    var removalRequest: [UUID]?
    /// The PDF being renamed (see `PDFActionAlerts`).
    var renameRequest: UUID?
    /// A PDF whose file couldn't be found when opening or sharing it (see `PDFActionAlerts`).
    var missingFileRequest: UUID?
    /// The files Quick Look is showing from the library's list, and the one
    /// on screen (`nil` when it's closed).
    var quickLookFiles: [URL] = []
    var quickLookFile: URL?
    /// The reader's side panels: beside the page, or over it in a narrow window.
    let readerPanels = ReaderPanels()

    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored private let preferences: UserDefaults
    private static let openKey = "openDocuments"
    private static let selectedKey = "selectedDocument"

    init(library: LibraryStore, preferences: UserDefaults = .standard) {
        self.library = library
        self.preferences = preferences
    }

    var selectedDocument: OpenDocument? {
        documents.first { $0.id == selectedID }
    }

    var isShowingLibrary: Bool { selectedDocument == nil }

    /// Opens a PDF (or switches to it if it's already open), optionally
    /// scrolling to one of its highlights.
    func open(_ entry: LibraryEntry, at highlight: HighlightRecord? = nil) {
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
    }

    /// Opens a PDF at a page (0-based), as when clicking a search match.
    func open(_ entry: LibraryEntry, atPage pageIndex: Int) {
        open(entry)
        selectedDocument?.pendingPageIndex = pageIndex
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

    /// Closes a PDF. If it was on screen, the library comes back.
    func close(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].close()
        documents.remove(at: index)
        if selectedID == id { selectedID = nil }
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
    func restore() {
        let ids = (preferences.stringArray(forKey: Self.openKey) ?? []).compactMap(UUID.init(uuidString:))
        for id in ids where !documents.contains(where: { $0.id == id }) {
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
    }
}
