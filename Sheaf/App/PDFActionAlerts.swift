import SwiftUI

/// The questions the PDF commands ask, over whatever the window shows:
/// removing PDFs from the library, renaming one, and what to do about a PDF
/// whose file can't be found. The commands set a request on the workspace.
struct PDFActionAlerts: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @Environment(\.undoManager) private var undoManager
    @State private var titleDraft = ""

    func body(content: Content) -> some View {
        let removing = workspace.removalRequest.map(entries) ?? []
        let summary = RemovalSummary(removing)
        let renaming = workspace.renameRequest.flatMap(workspace.library.entry(id:))
        let missing = workspace.missingFileRequest.flatMap(workspace.library.entry(id:))
        content
            .alert(summary.title, isPresented: isPresented(\.removalRequest)) {
                Button("Remove", role: .destructive) {
                    workspace.remove(removing.map(\.id), undoManager: undoManager)
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
            .alert(
                "Can\u{2019}t Find \u{201C}\(missing?.title ?? "")\u{201D}",
                isPresented: isPresented(\.missingFileRequest),
                presenting: missing
            ) { entry in
                // Choosing this is the confirmation; Undo still brings it back.
                Button("Remove from Library", role: .destructive) {
                    workspace.remove([entry.id], undoManager: undoManager)
                }
                Button("Keep", role: .cancel) {}
            } message: { entry in
                Text("It was last at \(entry.lastKnownPath). It may have been deleted, or moved to a drive that isn\u{2019}t connected.")
            }
    }

    private func entries(_ ids: [UUID]) -> [LibraryEntry] {
        ids.compactMap(workspace.library.entry(id:))
    }

    /// Shows an alert while the request is set, and clears it when the alert closes.
    private func isPresented<Value>(_ request: ReferenceWritableKeyPath<Workspace, Value?>) -> Binding<Bool> {
        Binding(
            get: { workspace[keyPath: request] != nil },
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
        let bookmarks = entries.reduce(0) { $0 + $1.bookmarkedPages.count }
        let counts = [(highlights, "highlight"), (notes, "note"), (bookmarks, "bookmark")].filter { $0.0 > 0 }

        var sentences: [String] = []
        if !counts.isEmpty {
            let things = Self.list(counts.map { $0.0 == 1 ? "1 \($0.1)" : "\($0.0) \($0.1)s" })
            let verb = counts.count == 1 && counts[0].0 == 1 ? "is" : "are"
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
        message = sentences.joined(separator: " ")
    }

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}
