import Foundation
import PDFKit
@testable import Sheaf

/// Files on disk for tests, each in its own new temporary folder.
@MainActor
enum TestFiles {
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SheafFiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A PDF with one page per string.
    static func pdf(named name: String = "Paper.pdf", pages: [String]) throws -> URL {
        let url = try folder().appending(path: name)
        guard TestPDF.make(pages: pages).write(to: url) else {
            struct CouldNotWrite: Error {}
            throw CouldNotWrite()
        }
        return url
    }

    /// A PDF with printed page labels (see `TestPDF.labeledData`).
    static func pdf(named name: String = "Paper.pdf", pages: [String], labels: String) throws -> URL {
        let url = try folder().appending(path: name)
        try TestPDF.labeledData(pages: pages, labels: labels).write(to: url)
        return url
    }

    /// A Sheaf highlight over `text` in the PDF at `url`, as Sheaf writes it.
    static func highlight(
        of text: String, in url: URL, kind: HighlightKind = .keyIdea, note: String = "", id: UUID = UUID()
    ) throws -> HighlightSnapshot {
        struct NotFound: Error {}
        guard let document = PDFDocument(url: url),
              let selection = document.findString(text, withOptions: []).first,
              let page = selection.pages.first
        else { throw NotFound() }
        return HighlightSnapshot(
            id: id,
            pageIndex: document.index(for: page),
            kindRaw: kind.rawValue,
            text: text,
            note: note,
            rects: selection.selectionsByLine().map { $0.bounds(for: page) },
            createdAt: .now,
            colorHex: kind.pageColorHex
        )
    }

    /// Changes a file's or folder's POSIX permissions, such as 0o555 for
    /// read-only, to make writing it fail.
    static func setPermissions(_ permissions: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path(percentEncoded: false))
    }
}
