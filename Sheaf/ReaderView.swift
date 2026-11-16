import PDFKit
import SwiftUI

/// The contents of one document window: opens the PDF, asks for a password
/// if it has one, then shows the reader.
struct ReaderView: View {
    let data: Data
    let fileURL: URL?

    @Environment(LibraryStore.self) private var library

    private enum Phase {
        case loading
        case locked(PDFDocument)
        case ready(ReaderModel)
        case failed
    }

    @State private var phase = Phase.loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
            case .locked(let document):
                UnlockView(document: document) {
                    phase = .ready(makeModel(for: document))
                }
            case .ready(let model):
                DocumentWindow(model: model)
            case .failed:
                ContentUnavailableView(
                    "Can't Open This PDF",
                    systemImage: "doc.questionmark",
                    description: Text("The file may be damaged or may not be a PDF.")
                )
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            // Parse once per window, not on every view update.
            guard case .loading = phase else { return }
            guard let document = PDFDocument(data: data) else {
                phase = .failed
                return
            }
            phase = document.isLocked ? .locked(document) : .ready(makeModel(for: document))
        }
    }

    /// Adds the PDF to the library (or finds it there) and sets up the reader.
    private func makeModel(for document: PDFDocument) -> ReaderModel {
        let item = fileURL.map { library.recordOpen(of: $0, document: document) }
        return ReaderModel(document: document, libraryItem: item)
    }
}

/// Asks for the password of an encrypted PDF.
private struct UnlockView: View {
    let document: PDFDocument
    let onUnlock: () -> Void

    @State private var password = ""
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("This PDF Is Password-Protected")
                .font(.title3.weight(.semibold))
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(unlock)
            if didFail {
                Text("That password didn't work. Try again.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Button("Unlock", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
        }
        .padding(32)
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        if document.unlock(withPassword: password) {
            onUnlock()
        } else {
            didFail = true
            password = ""
        }
    }
}
