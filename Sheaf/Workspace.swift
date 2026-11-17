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

/// One open PDF: loads the file, asks for a password if needed, and keeps
/// its reader (page, zoom, search) while you switch to the library and back.
@Observable
final class OpenDocument: Identifiable {
    enum Phase {
        case loading
        case locked(PDFDocument, URL)
        case ready(ReaderModel)
        case failed(title: String, message: String)
    }

    let id: UUID
    private(set) var title: String
    private(set) var phase = Phase.loading
    /// A highlight to scroll to once the reader is on screen.
    var pendingHighlightID: UUID?

    @ObservationIgnored let entry: LibraryEntry
    @ObservationIgnored private let library: LibraryStore

    init(entry: LibraryEntry, library: LibraryStore) {
        self.id = entry.id
        self.title = entry.title
        self.entry = entry
        self.library = library
        load()
    }

    var model: ReaderModel? {
        if case .ready(let model) = phase { return model }
        return nil
    }

    /// Tries a password for a protected PDF. Returns false if it was wrong.
    func unlock(with password: String) -> Bool {
        guard case .locked(let document, let url) = phase, document.unlock(withPassword: password) else { return false }
        phase = .ready(makeModel(document: document, url: url))
        return true
    }

    func close() {
        model?.close()
    }

    private func load() {
        guard let url = library.resolveFile(for: entry) else {
            phase = .failed(
                title: "Can\u{2019}t Find \u{201C}\(entry.title)\u{201D}",
                message: "It was last at \(entry.lastKnownPath). It may have been deleted, or moved to a drive that isn\u{2019}t connected."
            )
            return
        }
        // Read the file into memory, so saving highlights into it later
        // can't disturb the copy on screen.
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else {
            phase = .failed(
                title: "Can\u{2019}t Open This PDF",
                message: "\u{201C}\(entry.title)\u{201D} may be damaged or may not be a PDF."
            )
            return
        }
        phase = document.isLocked ? .locked(document, url) : .ready(makeModel(document: document, url: url))
    }

    private func makeModel(document: PDFDocument, url: URL) -> ReaderModel {
        library.recordOpen(of: url, document: document)
        title = entry.title
        return ReaderModel(document: document, entry: entry, store: library, fileURL: url)
    }
}

/// The app's single window: the library, or the PDF that's open on screen.
struct MainWindow: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let document = workspace.selectedDocument {
                ReaderScreen(document: document)
                    .id(document.id)
            } else {
                LibraryWindow()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { WindowRouter.shared.attach(openWindow) }
    }
}
