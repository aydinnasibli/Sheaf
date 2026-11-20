import CoreGraphics
import Foundation
import PDFKit
import SwiftData
import Testing
@testable import Sheaf

/// Saving highlights rewrites the PDF with PDFKit, which leaves out what it
/// doesn't understand. Files that would lose content that way are left as
/// they are; printed page numbers and other catalog settings are put back.
@MainActor
struct PDFRewriteTests {
    static let pages = ["Preface", "Contents", "Chapter one", "More of chapter one"]

    private func file(_ data: Data) throws -> URL {
        let url = try TestFiles.folder().appending(path: "Paper.pdf")
        try data.write(to: url)
        return url
    }

    // MARK: Page labels and other catalog entries

    @Test func printedPageNumbersAndDocumentSettingsSurviveSaving() throws {
        let url = try file(TestPDF.handWritten(pages: Self.pages, catalog: """
            /PageLabels << /Nums [0 << /S /r >> 2 << /S /D /St 245 /P (p. ) >>] >> \
            /Lang (en-GB) /ViewerPreferences << /Direction /R2L /DisplayDocTitle true >> \
            /PageMode /UseOutlines /PageLayout /TwoPageRight
            """))
        let labels = ["i", "ii", "p. 245", "p. 246"]
        let first = try TestFiles.highlight(of: "Chapter one", in: url)
        #expect(PDFHighlightWriter.write([first], to: url) == .saved)
        try expectRestored(url, labels: labels, highlights: [first])

        // Saving again starts from the file with Sheaf's update in it.
        let second = try TestFiles.highlight(of: "Preface", in: url)
        #expect(PDFHighlightWriter.write([first, second], to: url) == .saved)
        try expectRestored(url, labels: labels, highlights: [first, second])
    }

    @Test func labelsKeptInSeveralPartsOfTheFileComeThrough() throws {
        let pages = Self.pages
        let kid = TestPDF.firstObject(after: pages)
        // The labels' number tree split in two nodes, as long books have it,
        // with a prefix that needs escaping: "p. (x) café 245".
        let url = try file(TestPDF.handWritten(
            pages: pages,
            catalog: "/PageLabels << /Kids [\(kid) 0 R \(kid + 1) 0 R] >>",
            objects: [
                "<< /Limits [0 1] /Nums [0 << /S /r >>] >>",
                "<< /Limits [2 3] /Nums [2 << /S /D /St 245 /P (p. \\(x\\) caf\\351 ) >>] >>",
            ]
        ))
        let labels = try #require(PDFDocument(url: url)).labels
        #expect(labels == ["i", "ii", "p. (x) caf\u{E9} 245", "p. (x) caf\u{E9} 246"])

        let highlight = try TestFiles.highlight(of: "Contents", in: url)
        #expect(PDFHighlightWriter.write([highlight], to: url) == .saved)
        try expectRestored(url, labels: labels, highlights: [highlight], settings: false)
    }

    @Test func aReaderKeepsPageLabelsInTheFileItSaves() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let store = LibraryStore(context: container.mainContext)
        let url = try TestFiles.pdf(pages: Self.pages, labels: "0 << /S /r >> 2 << /S /D /St 245 >>")
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences)
        model.pdfView.currentSelection = try #require(document.findString("Chapter one", withOptions: []).first)
        #expect(model.highlightSelection(as: .evidence))
        await model.saveAndWait()

        #expect(model.saveError == nil)
        let saved = try #require(PDFDocument(url: url))
        #expect(PDFHighlights.ids(in: saved).count == 1)
        // From the file itself, not from what the library remembers.
        #expect(PageLabels.read(from: saved) == ["i", "ii", "245", "246"])
    }

    // MARK: Files that would lose content

    @Test func filesWithAttachmentsLayersOrMediaAreLeftAsTheyAre() throws {
        let pages = ["Exam question one", "Exam question two"]
        let first = TestPDF.firstObject(after: pages)
        let payload = "<< /Type /EmbeddedFile /Length 5 >>\nstream\nhello\nendstream"
        let cases: [(name: String, data: Data, loss: PDFContentCheck.Loss)] = [
            ("attached file", TestPDF.handWritten(
                pages: pages,
                catalog: "/Names << /EmbeddedFiles << /Names [(notes.txt) \(first) 0 R] >> >>",
                objects: ["<< /Type /Filespec /F (notes.txt) /EF << /F \(first + 1) 0 R >> >>", payload]
            ), .attachments),
            ("file attachment annotation", TestPDF.handWritten(
                pages: pages,
                pageEntries: [1: "/Annots [<< /Type /Annot /Subtype /FileAttachment /Rect [72 600 90 620] /FS << /Type /Filespec /F (data.csv) /EF << /F \(first) 0 R >> >> >>]"],
                objects: [payload]
            ), .attachments),
            ("hidden layer", TestPDF.handWritten(
                pages: pages,
                catalog: "/OCProperties << /OCGs [\(first) 0 R] /D << /Order [\(first) 0 R] /OFF [\(first) 0 R] >> >>",
                resources: [0: "/Properties << /oc1 \(first) 0 R >>"],
                content: [0: "/OC /oc1 BDC BT /F1 14 Tf 72 600 Td (The answer is 42) Tj ET EMC"],
                objects: ["<< /Type /OCG /Name (Answers) >>"]
            ), .layers),
            ("sound", TestPDF.handWritten(
                pages: pages,
                pageEntries: [0: "/Annots [<< /Type /Annot /Subtype /Sound /Rect [72 600 90 620] /Sound \(first) 0 R >>]"],
                objects: ["<< /Type /Sound /R 8000 /Length 4 >>\nstream\nabcd\nendstream"]
            ), .media),
            ("portfolio", TestPDF.handWritten(pages: pages, catalog: "/Collection << /Type /Collection /View /D >>"), .portfolio),
            ("XFA form", TestPDF.handWritten(
                pages: pages,
                catalog: "/AcroForm << /Fields [] /XFA \(first) 0 R >>",
                objects: ["<< /Length 6 >>\nstream\n<xdp/>\nendstream"]
            ), .xfaForm),
        ]

        for (name, data, loss) in cases {
            let url = try file(data)
            #expect(PDFDocument(url: url)?.pageCount == 2, "The \(name) test file opens")
            let highlight = try TestFiles.highlight(of: "question one", in: url)
            #expect(PDFHighlightWriter.write([highlight], to: url) == .wouldLoseContent([loss]), "A PDF with a \(name)")
            #expect(try Data(contentsOf: url) == data, "A PDF with a \(name) is left as it was")
        }
    }

    @Test func aPlainPDFHasNothingToLose() throws {
        let data = try #require(TestPDF.make(pages: ["Plain"]).dataRepresentation())
        let document = try #require(PDFContentCheck.document(from: data))
        #expect(PDFContentCheck.losses(in: document).isEmpty)
        #expect(!PDFContentCheck.hasSignedPermissions(document))
        // Nor does one whose list of attached files is empty.
        let empty = TestPDF.handWritten(pages: ["Plain"], catalog: "/Names << /EmbeddedFiles << /Names [] >> >>")
        #expect(PDFContentCheck.losses(in: try #require(PDFContentCheck.document(from: empty))).isEmpty)
    }

    @Test func certifiedPDFsCountAsSigned() throws {
        let pages = ["Certified"]
        let url = try file(TestPDF.handWritten(
            pages: pages, catalog: "/Perms << /UR3 \(TestPDF.firstObject(after: pages)) 0 R >>",
            objects: ["<< /Type /Sig /Filter /Adobe.PPKLite >>"]
        ))
        let before = try Data(contentsOf: url)
        let highlight = try TestFiles.highlight(of: "Certified", in: url)
        #expect(PDFHighlightWriter.write([highlight], to: url) == .signed)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func theReaderSaysWhyHighlightsStayInTheLibrary() async throws {
        let container = try LibraryStore.makeContainer(inMemory: true)
        let store = LibraryStore(context: container.mainContext)
        let pages = ["With an attachment"]
        let first = TestPDF.firstObject(after: pages)
        let data = TestPDF.handWritten(
            pages: pages,
            catalog: "/Names << /EmbeddedFiles << /Names [(notes.txt) \(first) 0 R] >> >> /OCProperties << /OCGs [] >>",
            objects: ["<< /Type /Filespec /F (notes.txt) /EF << /F \(first + 1) 0 R >> >>", "<< /Length 5 >>\nstream\nhello\nendstream"]
        )
        let url = try file(data)
        let document = try #require(PDFDocument(url: url))
        let entry = store.recordOpen(of: url, document: document)
        let preferences = try #require(UserDefaults(suiteName: "SheafTests.\(UUID().uuidString)"))
        let model = ReaderModel(document: document, entry: entry, store: store, fileURL: url, preferences: preferences)
        model.pdfView.currentSelection = try #require(document.findString("attachment", withOptions: []).first)
        #expect(model.highlightSelection(as: .keyIdea))
        await model.saveAndWait()

        #expect(model.fileWriteBlock == .wouldLoseContent([.attachments, .layers]))
        #expect(model.fileWriteBlock?.explanation.contains("attached files and layers that can be shown or hidden") == true)
        #expect(model.saveError == nil)
        #expect(model.highlights.count == 1)
        #expect(try Data(contentsOf: url) == data)
    }

    // MARK: Putting the catalog back safely

    @Test func theCatalogIsOnlyPutBackIntoAFileLaidOutAsExpected() throws {
        let lang = [(key: "Lang", value: "<656E>")]
        #expect(PDFCatalogRestore.appending(lang, to: Data("not a PDF".utf8)) == nil)
        let output = try #require(TestPDF.make(pages: ["One"]).dataRepresentation())
        #expect(PDFCatalogRestore.appending([], to: output) == nil, "Nothing to put back")
        let updated = try #require(PDFCatalogRestore.appending(lang, to: output))
        #expect(PDFCatalogRestore.appending(lang, to: updated) == nil, "A file updated before isn't PDFKit's own output")
        // A cut-off file.
        #expect(PDFCatalogRestore.appending(lang, to: output.prefix(output.count - 40)) == nil)
    }

    @Test func aRestoredFileThatDoesntCheckOutIsntUsed() throws {
        let output = try #require(TestPDF.make(pages: ["One", "Two"]).dataRepresentation())
        let restored = try #require(PDFCatalogRestore.appending([(key: "Lang", value: "<656E>")], to: output))
        #expect(PDFCatalogRestore.isIntact(restored, comparedWith: output, adding: ["Lang"]))
        #expect(!PDFCatalogRestore.isIntact(restored, comparedWith: output, adding: ["Lang", "PageLabels"]))
        #expect(PDFHighlightWriter.isComplete(restored, pageCount: 2, highlights: [], labels: ["1", "2"]))
        #expect(!PDFHighlightWriter.isComplete(restored, pageCount: 2, highlights: [], labels: ["i", "ii"]))
    }

    @Test func valuesAreCopiedInFullOrNotAtAll() throws {
        // Object 5 is the page's content, a stream: it can't be copied in
        // place, so that entry is left out.
        let data = TestPDF.handWritten(pages: ["One"], catalog: """
            /ViewerPreferences << /PrintPageRange [0 0] /Odd#20Name true /Ratio 0.5 /Title (A \\(b\\)) >> \
            /PageMode 5 0 R
            """)
        let original = try #require(PDFContentCheck.document(from: data))
        let written = try #require(TestPDF.make(pages: ["One"]).dataRepresentation())
        let output = try #require(PDFContentCheck.document(from: written))
        let entries = PDFCatalogRestore.lostEntries(of: original, in: output)
        #expect(entries.map(\.key) == ["ViewerPreferences"])
        #expect(entries.first?.value == "<< /Odd#20Name true /PrintPageRange [0 0] /Ratio 0.5 /Title <4120286229> >>")
    }

    // MARK: Helpers

    /// Checks the saved file: the labels, the highlights, the catalog
    /// settings (with `settings`), and that its end is laid out exactly.
    private func expectRestored(
        _ url: URL, labels: [String], highlights: [HighlightSnapshot], settings: Bool = true
    ) throws {
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == Self.pages.count)
        #expect(document.labels == labels)
        #expect(PDFHighlights.ids(in: document) == Set(highlights.map(\.id)))

        let data = try Data(contentsOf: url)
        let source = try #require(PDFContentCheck.document(from: data))
        #expect(source.numberOfPages == Self.pages.count)
        let catalog = try #require(source.catalog)
        if settings {
            #expect(string(catalog, "Lang") == "en-GB")
            #expect(name(catalog, "PageMode") == "UseOutlines")
            #expect(name(catalog, "PageLayout") == "TwoPageRight")
            var preferences: CGPDFDictionaryRef?
            #expect(CGPDFDictionaryGetDictionary(catalog, "ViewerPreferences", &preferences))
            #expect(preferences.flatMap { name($0, "Direction") } == "R2L")
            var showsTitle: CGPDFBoolean = 0
            #expect(preferences.map { CGPDFDictionaryGetBoolean($0, "DisplayDocTitle", &showsTitle) } == true && showsTitle != 0)
        }
        try expectLaidOutExactly(data)
    }

    /// The last cross-reference table is where "startxref" says, its entry
    /// for the catalog points at the catalog, and the table before it is
    /// where "/Prev" says: other PDF readers find everything without having
    /// to repair the file.
    private func expectLaidOutExactly(_ data: Data) throws {
        func text(at offset: Int, length: Int = 400) -> String {
            String(decoding: data[offset..<min(offset + length, data.count)], as: UTF8.self)
        }
        let tail = text(at: data.count - 60, length: 60)
        let startxref = try #require(tail.range(of: "startxref"))
        let table = try #require(Int(tail[startxref.upperBound...].split(whereSeparator: \.isWhitespace).first ?? ""))
        let lines = text(at: table).split(whereSeparator: \.isNewline)
        #expect(lines.first == "xref")
        let section = lines[1].split(separator: " ")
        #expect(section.last == "1")
        let catalogNumber = try #require(section.first.flatMap { Int($0) })
        let entry = String(lines[2])
        let catalogOffset = try #require(Int(entry.prefix(10)))
        #expect(text(at: catalogOffset).hasPrefix("\(catalogNumber) 0 obj"))
        #expect(text(at: table).contains("/Root \(catalogNumber) 0 R"))
        let previous = try #require(text(at: table).firstMatch(of: /\/Prev (\d+)/).flatMap { Int($0.1) })
        #expect(text(at: previous).hasPrefix("xref"))
    }

    private func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    private func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}

private extension PDFDocument {
    /// Each page's label as PDFKit reads it.
    var labels: [String] { PDFHighlightWriter.pageLabels(of: self) }
}
