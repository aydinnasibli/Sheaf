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

    enum Page {
        /// A line of real text at (72, 700).
        case text(String)
        /// A picture of a line of text, like a scanned page: nothing to select.
        case scanned(String)
    }

    /// Where `scanned` pages draw their line, in page coordinates.
    static let scannedLineRect = CGRect(x: 72, y: 690, width: 468, height: 40)

    static func make(_ pages: [Page]) -> PDFDocument {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { fatalError("Couldn't create a PDF context") }

        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text):
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: 14)]
                ))
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
            case .scanned(let text):
                context.draw(picture(of: text, size: mediaBox.size), in: mediaBox)
            }
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else { fatalError("PDFKit couldn't read the test PDF") }
        return document
    }

    /// A PDF with printed page labels, one page per string, each drawn as a
    /// line of text at (72, 700). `labels` is the PDF's /PageLabels number
    /// tree, like `0 << /S /r >> 2 << /S /D /St 245 >>` for i, ii, 245, 246.
    /// Written by hand: Core Graphics and PDFKit can't write page labels.
    static func labeledData(pages: [String], labels: String) -> Data {
        let kids = pages.indices.map { "\(4 + $0 * 2) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [\(labels)] >> >>",
            "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        for (index, text) in pages.enumerated() {
            let content = "BT /F1 14 Tf 72 700 Td (\(text)) Tj ET"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(5 + index * 2) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        var file = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let table = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(format: "%010d 00000 n \n", offset) }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        return Data(file.utf8)
    }

    static func make(pages: [String], labels: String) -> PDFDocument {
        guard let document = PDFDocument(data: labeledData(pages: pages, labels: labels)) else {
            fatalError("PDFKit couldn't read the labeled test PDF")
        }
        return document
    }

    /// A page-sized image (at 2x) with a large line of text in `scannedLineRect`.
    private static func picture(of text: String, size: CGSize) -> CGImage {
        let scale: CGFloat = 2
        guard let bitmap = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { fatalError("Couldn't create a bitmap") }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        bitmap.scaleBy(x: scale, y: scale)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black]
        ))
        bitmap.textPosition = CGPoint(x: scannedLineRect.minX, y: scannedLineRect.minY + 10)
        CTLineDraw(line, bitmap)
        guard let image = bitmap.makeImage() else { fatalError("Couldn't draw the scanned page") }
        return image
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
