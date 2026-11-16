import PDFKit
import SwiftUI

/// The contents of one document window.
struct ReaderView: View {
    let data: Data

    private enum LoadState {
        case loading
        case loaded(PDFDocument)
        case failed
    }

    @State private var state = LoadState.loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
            case .loaded(let document):
                PDFKitView(document: document)
            case .failed:
                ContentUnavailableView(
                    "Can't Open This PDF",
                    systemImage: "doc.questionmark",
                    description: Text("The file may be damaged or may not be a PDF.")
                )
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task {
            // Parse once per window, not on every view update.
            if let document = PDFDocument(data: data) {
                state = .loaded(document)
            } else {
                state = .failed
            }
        }
    }
}
