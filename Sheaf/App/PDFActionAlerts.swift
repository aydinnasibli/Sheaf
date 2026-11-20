import SwiftUI

/// The questions the PDF commands ask, over whatever the window shows:
/// removing PDFs from the library, renaming one, naming a new collection,
/// and what to do about a PDF whose file can't be found. The commands set a
/// request on the workspace, and the window that was in front when they did
/// asks it.
struct PDFActionAlerts: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(ReaderWindow.self) private var readerWindow
    @Environment(\.undoManager) private var undoManager
    @State private var titleDraft = ""
    @State private var collectionName = ""

    /// Removing a PDF from its own window closes that window, so Undo goes
    /// to the main window, where the library is.
    private var removalUndoManager: UndoManager? {
        readerWindow.isMain ? undoManager : workspace.mainWindow.undoManager ?? undoManager
    }

    func body(content: Content) -> some View {
        let removing = workspace.removalRequest.map(entries) ?? []
        let summary = RemovalSummary(removing)
        let renaming = workspace.renameRequest.flatMap(workspace.library.entry(id:))
        let missing = workspace.missingFileRequest.flatMap(workspace.library.entry(id:))
        let filing = workspace.newCollectionRequest.map(entries) ?? []
        content
            .alert(summary.title, isPresented: isPresented(\.removalRequest)) {
                Button("Remove", role: .destructive) {
                    workspace.remove(removing.map(\.id), undoManager: removalUndoManager)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(summary.message)
            }
            .alert("Rename PDF", isPresented: isPresented(\.renameRequest)) {
                TextField("Title", text: $titleDraft)
                Button("Rename") {
                    if let renaming { workspace.rename(renaming.id, to: titleDraft, undoManager: undoManager) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let renaming {
                    Text("This changes the title shown in Sheaf. The file keeps its name, \u{201C}\(URL(filePath: renaming.lastKnownPath).lastPathComponent)\u{201D}.")
                }
            }
            .onChange(of: workspace.renameRequest, initial: true) {
                if let renaming { titleDraft = renaming.title }
            }
            .alert("New Collection", isPresented: isPresented(\.newCollectionRequest)) {
                TextField("Name", text: $collectionName)
                Button("Create") {
                    workspace.createCollection(named: collectionName, with: filing.map(\.id))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let message = Self.newCollectionMessage(filing) { Text(message) }
            }
            .onChange(of: workspace.newCollectionRequest) { collectionName = "" }
            .alert(
                "Can\u{2019}t Find \u{201C}\(missing?.title ?? "")\u{201D}",
                isPresented: isPresented(\.missingFileRequest),
                presenting: missing
            ) { entry in
                // Choosing this is the confirmation; Undo still brings it back.
                Button("Remove from Library", role: .destructive) {
                    workspace.remove([entry.id], undoManager: removalUndoManager)
                }
                Button("Keep", role: .cancel) {}
            } message: { entry in
                Text("It was last at \(entry.lastKnownPath). It may have been deleted, or moved to a drive that isn\u{2019}t connected.")
            }
    }

    private func entries(_ ids: [UUID]) -> [LibraryEntry] {
        ids.compactMap(workspace.library.entry(id:))
    }

    /// Under the new collection's name: which PDFs go in it, if any.
    static func newCollectionMessage(_ entries: [LibraryEntry]) -> String? {
        switch entries.count {
        case 0: nil
        case 1: "\u{201C}\(entries[0].title)\u{201D} goes in it."
        default: "The \(entries.count) selected PDFs go in it."
        }
    }

    /// Shows an alert while the request is set, in the window it was made
    /// in only, and clears it when the alert closes.
    private func isPresented<Value>(_ request: ReferenceWritableKeyPath<Workspace, Value?>) -> Binding<Bool> {
        Binding(
            get: { workspace.alertWindow == readerWindow.kind && workspace[keyPath: request] != nil },
            set: { if !$0 { workspace[keyPath: request] = nil } }
        )
    }
}

/// What the confirmation for removing PDFs says: what's deleted from Sheaf,
/// and, truthfully, what stays.
struct RemovalSummary: Equatable {
    let title: String
    let message: String

    init(_ entries: [LibraryEntry]) {
        let one = entries.count == 1
        title = one
            ? "Remove \u{201C}\(entries[0].title)\u{201D} from your library?"
            : "Remove \(entries.count) PDFs from your library?"

        let highlights = entries.reduce(0) { $0 + $1.highlights.count }
        let notes = entries.reduce(0) { total, entry in total + entry.highlights.count { !$0.note.isEmpty } }
        let pageNotes = entries.reduce(0) { $0 + $1.pageNotes.count }
        let answers = entries.reduce(0) { total, entry in total + entry.highlights.count(where: \.isAnsweredQuestion) }
        let summaries = entries.count { !$0.summary.isEmpty }
        let bookmarks = entries.reduce(0) { $0 + $1.bookmarkedPages.count }
        // Never written into the PDF: these exist only in Sheaf.
        let onlyInSheaf = [
            Count(pageNotes, "page note", "page notes"), Count(answers, "answer", "answers"),
            Count(summaries, "summary", "summaries"),
        ].filter { $0.number > 0 }
        let counts = ([Count(highlights, "highlight", "highlights"), Count(notes, "note", "notes")]
            + onlyInSheaf + [Count(bookmarks, "bookmark", "bookmarks")]).filter { $0.number > 0 }

        var sentences: [String] = []
        if !counts.isEmpty {
            let things = Self.list(counts.map { $0.number == 1 ? "1 \($0.one)" : "\($0.number) \($0.many)" })
            let verb = counts.count == 1 && counts[0].number == 1 ? "is" : "are"
            sentences.append("\(one ? "Its" : "Their") \(things) in Sheaf \(verb) deleted.")
        }
        // Highlights and notes are also saved into the PDF itself, unless it
        // can't be changed (password-protected or signed), so only those stay.
        if highlights > 0 {
            let saved = notes > 0 ? "the highlights and notes Sheaf saved into" : "the highlights Sheaf saved into"
            sentences.append(one
                ? "The PDF stays where it is, with \(saved) it."
                : "The PDFs stay where they are, with \(saved) them.")
        } else {
            sentences.append(one
                ? "The PDF itself stays where it is on your Mac."
                : "The PDFs themselves stay where they are on your Mac.")
        }
        if !onlyInSheaf.isEmpty {
            let things = Self.list(onlyInSheaf.map { $0.number == 1 ? $0.one : $0.many })
            let verb = onlyInSheaf.count == 1 && onlyInSheaf[0].number == 1 ? "is" : "are"
            sentences.append(one
                ? "Its \(things) \(verb) kept only in Sheaf, not in the file."
                : "Their \(things) \(verb) kept only in Sheaf, not in the files.")
        }
        message = sentences.joined(separator: " ")
    }

    /// A number of things, and what one and several of them are called.
    private struct Count {
        let number: Int
        let one: String
        let many: String

        init(_ number: Int, _ one: String, _ many: String) {
            self.number = number
            self.one = one
            self.many = many
        }
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

/// What the confirmation for deleting a collection says: the collection
/// goes, its PDFs don't.
struct CollectionDeletionSummary: Equatable {
    let title: String
    let message: String

    init(_ collection: PDFCollection) {
        title = "Delete the collection \u{201C}\(collection.name)\u{201D}?"
        message = switch collection.items.count {
        case 0: "It has no PDFs in it."
        case 1: "The PDF in it stays in your library, with its highlights and notes."
        case let count: "The \(count) PDFs in it stay in your library, with their highlights and notes."
        }
    }
}
