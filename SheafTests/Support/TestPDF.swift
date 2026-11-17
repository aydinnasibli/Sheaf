import AppKit
import CoreText
import PDFKit

/// Builds small PDFs in memory so tests don't depend on files on disk.
enum TestPDF {
    /// One page per string, with the string drawn as a line of text.
    static func make(pages: [String]) -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { fatalError("Couldn't create a PDF context") }

        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            ))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else { fatalError("PDFKit couldn't read the test PDF") }
        return document
    }
}

/// Waits for asynchronous work, such as PDFKit's background search, to finish.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            struct TimedOut: Error {}
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
