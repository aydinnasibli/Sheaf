import AppKit
import Observation
import PDFKit
import SwiftUI

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
    /// A page (0-based) to go to once the reader is on screen.
    var pendingPageIndex: Int?

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
