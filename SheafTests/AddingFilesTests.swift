import AppKit
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Adding PDFs by dropping files and folders, or choosing folders in File › Open.
@MainActor
struct AddingFilesTests {
    private let container: ModelContainer
    private let store: LibraryStore
    private let folder: URL

    init() throws {
        container = try LibraryStore.makeContainer(inMemory: true)
        store = LibraryStore(context: container.mainContext)
        folder = FileManager.default.temporaryDirectory.appending(path: "SheafAdding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func allItems() throws -> [LibraryEntry] {
        try container.mainContext.fetch(FetchDescriptor<LibraryEntry>())
    }

    /// A real PDF at a path inside this test's folder, making folders as needed.
    @discardableResult
    private func writePDF(_ path: String) throws -> URL {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(TestPDF.make(pages: [url.lastPathComponent]).write(to: url))
        return url
    }

    @Test func addingAFolderAddsNestedPDFs() async throws {
        let course = folder.appending(path: "Biology")
        try writePDF("Biology/Syllabus.pdf")
        try writePDF("Biology/Week 2/Cells.pdf")
        try writePDF("Biology/Week 2/Readings/Membranes.pdf")
        try writePDF("Biology/.Hidden.pdf")
        try "not a PDF".write(to: course.appending(path: "Notes.txt"), atomically: true, encoding: .utf8)

        let added = await store.addFiles([course])

        #expect(added.map(\.title) == ["Syllabus", "Cells", "Membranes"])
        #expect(try allItems().count == 3)
        #expect(added.allSatisfy { $0.bookmark != nil && $0.collection == nil })
        #expect(store.resolveFile(for: added[2])?.lastPathComponent == "Membranes.pdf")

        // Adding the folder again doesn't add the PDFs twice.
        await store.addFiles([course])
        #expect(try allItems().count == 3)
    }

    @Test func aDropIntoACollectionLandsThere() async throws {
        let exams = store.createCollection(named: "Exams")
        let work = store.createCollection(named: "Work")
        let loose = try writePDF("Loose.pdf")
        let alreadyThere = try #require(store.add(urls: [try writePDF("Already in Work.pdf")]).first)
        store.move([alreadyThere], to: work)
        try writePDF("Dropped folder/Inside.pdf")

        let added = await store.addFiles(
            [loose, folder.appending(path: "Already in Work.pdf"), folder.appending(path: "Dropped folder")],
            to: exams
        )

        #expect(added.count == 3)
        #expect(added.allSatisfy { $0.collection?.id == exams.id })
        #expect(Set(exams.items.map(\.title)) == ["Loose", "Already in Work", "Inside"])
        #expect(work.items.isEmpty)
        #expect(try allItems().count == 3)
    }

    @Test func aDropOnStarredStarsThePDFs() async throws {
        let added = await store.addFiles([try writePDF("Favorite.pdf")], starred: true)
        #expect(added.count == 1)
        #expect(added.allSatisfy { $0.isStarred })
    }

    @Test func onlyPDFsAndFoldersAreAccepted() throws {
        let pdf = try writePDF("Paper.pdf")
        let text = folder.appending(path: "Notes.txt")
        try "hi".write(to: text, atomically: true, encoding: .utf8)

        #expect(LibraryStore.isPDF(pdf))
        #expect(!LibraryStore.isPDF(text))
        #expect(LibraryStore.isFolder(folder))
        #expect(!LibraryStore.isFolder(pdf))
        #expect(LibraryStore.pdfFiles(in: [text, pdf, pdf]) == [pdf])
    }
}
