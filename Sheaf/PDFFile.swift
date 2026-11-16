import SwiftUI
import UniformTypeIdentifiers

/// A PDF opened from disk.
///
/// Sheaf only reads PDFs for now, so saving is unsupported. When annotations
/// are added, this is where writing changes back to the file will go.
nonisolated struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}
