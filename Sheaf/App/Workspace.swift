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
    private(set) var selectedID: UUID?
    /// Incremented by Find / Search Library (⌘F, ⌘K) to focus the library's search field.
    var librarySearchRequest = 0

    @ObservationIgnored private let library: LibraryStore
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

    /// Reopens the PDFs that were open when Sheaf last quit.
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
