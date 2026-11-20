import AppKit
import PDFKit
import Synchronization

/// A second copy of an open PDF, for drawing thumbnails and reading scanned
/// pages away from the main thread. PDFKit can't be used on one document
/// from two threads at once, so this copy lives inside an actor and nothing
/// else touches it.
///
/// The file is copied once into Sheaf's temporary folder (on the same
/// drive that's a clone, which takes no time or space) and the copy is
/// read from there as pages are needed, so a big scanned PDF isn't held in
/// memory a second time. Nothing else writes the copy, so saving highlights
/// into the PDF can't disturb it. It's deleted when the PDF closes.
actor PageRenderer {
    enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    enum Thumbnail: Sendable {
        case image(CGImage)
        /// The thumbnail is no longer wanted (its row scrolled away).
        case skipped
        /// The copy can't be read, for example because the PDF has a password.
        case unavailable
    }

    private let source: Source
    private let expectedPageCount: Int
    /// Where the copy of a file goes.
    private let copyURL: URL
    private var document: PDFDocument?
    private var hasLoaded = false
    /// Pages whose Sheaf highlights were taken out of the copy (they're
    /// drawn from the library instead, which is always up to date).
    private var cleanedPages = Set<Int>()
    /// How many thumbnails have been drawn, so tests can check the cache.
    private(set) var thumbnailsDrawn = 0

    /// Copies of files go in `copiesFolder`.
    init(source: Source, expectedPageCount: Int, copiesFolder: URL = PageRenderer.copiesFolder) {
        self.source = source
        self.expectedPageCount = expectedPageCount
        self.copyURL = copiesFolder.appending(path: "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).pdf")
    }

    deinit {
        try? FileManager.default.removeItem(at: copyURL)
    }

    /// In the temporary folder inside Sheaf's container.
    nonisolated static var copiesFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "Page Copies", directoryHint: .isDirectory)
    }

    /// Lets go of the copy: the PDF was closed. Nothing is drawn after this.
    func close() {
        document = nil
        hasLoaded = true
        try? FileManager.default.removeItem(at: copyURL)
    }

    /// Whether the copy is read from a file of its own (rather than memory).
    var isFileBacked: Bool {
        loadedDocument() != nil && FileManager.default.fileExists(atPath: copyURL.path(percentEncoded: false))
    }

    /// Whether the copy could be read.
    var isAvailable: Bool { loadedDocument() != nil }

    /// The page as a thumbnail that fits `size` (in pixels), with Sheaf's
    /// highlights drawn on it.
    func thumbnail(ofPage index: Int, fitting size: CGSize, highlights: [HighlightSnapshot]) -> Thumbnail {
        guard let document = loadedDocument() else { return .unavailable }
        guard !Task.isCancelled else { return .skipped }
        guard let page = cleanedPage(index, in: document),
              let image = PageImage.thumbnail(of: page, fitting: size, highlights: highlights)
        else { return .unavailable }
        thumbnailsDrawn += 1
        return .image(image)
    }

    /// A picture of the page, or part of it, for reading its text. Leaves
    /// out annotations, so highlights don't get in the way.
    func imageForReading(page index: Int, region: CGRect? = nil) -> PageImage? {
        guard !Task.isCancelled, let document = loadedDocument(), let page = document.page(at: index) else { return nil }
        page.displaysAnnotations = false
        defer { page.displaysAnnotations = true }
        return PageImage.forReading(page, region: region)
    }

    /// Of the pages in `range`, the ones with no selectable text, with a
    /// fingerprint of each to tell whether text read earlier still fits.
    /// Nil if the copy can't be read. Looks at a few pages per call, so
    /// thumbnails waiting for the actor don't wait long.
    func pagesWithoutText(in range: Range<Int>) -> [ScannedPageInfo]? {
        guard let document = loadedDocument() else { return nil }
        return range.compactMap { index in
            guard let page = document.page(at: index), !PageText.hasSelectableText(page) else { return nil }
            return ScannedPageInfo(index: index, fingerprint: PageText.fingerprint(of: page))
        }
    }

    private func loadedDocument() -> PDFDocument? {
        if hasLoaded { return document }
        hasLoaded = true
        let copy: PDFDocument?
        switch source {
        case .file(let url):
            // In memory as before, if the file can't be copied (the disk is full, say).
            copy = copyFile(url).flatMap(PDFDocument.init(url:)) ?? (try? Data(contentsOf: url)).flatMap(PDFDocument.init(data:))
        case .data(let bytes):
            copy = PDFDocument(data: bytes)
        }
        // A copy with a password can't be unlocked here (Sheaf doesn't keep
        // the password), and one with different pages isn't the same PDF.
        guard let copy, !copy.isLocked, copy.pageCount == expectedPageCount else {
            try? FileManager.default.removeItem(at: copyURL)
            return nil
        }
        document = copy
        return copy
    }

    /// Copies the file into `copyURL`, coordinated so it's never caught
    /// halfway through a save. Returns the copy, or nil if it failed.
    private func copyFile(_ url: URL) -> URL? {
        let folder = copyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.removeLeftoverCopies(in: folder)
        var copied = false
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { target in
            copied = (try? FileManager.default.copyItem(at: target, to: copyURL)) != nil
        }
        return copied ? copyURL : nil
    }

    /// Copies a Sheaf that quit unexpectedly left behind: from another run,
    /// and a day old. (Checked once per run.)
    private static func removeLeftoverCopies(in folder: URL) {
        guard !LeftoverCopies.checked.withLock({ checked in defer { checked = true }; return checked }) else { return }
        let ownPrefix = "\(ProcessInfo.processInfo.processIdentifier)-"
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where !file.lastPathComponent.hasPrefix(ownPrefix) {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < .now.addingTimeInterval(-86_400) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func cleanedPage(_ index: Int, in document: PDFDocument) -> PDFPage? {
        guard let page = document.page(at: index) else { return nil }
        if cleanedPages.insert(index).inserted {
            for annotation in page.annotations where PDFHighlightWriter.id(of: annotation) != nil {
                page.removeAnnotation(annotation)
            }
        }
        return page
    }
}

private nonisolated enum LeftoverCopies {
    static let checked = Mutex(false)
}

/// A scanned page found in the background, and its fingerprint.
nonisolated struct ScannedPageInfo: Sendable, Equatable, Codable {
    let index: Int
    let fingerprint: String
}

/// An image of a page (or part of one), and how to get from the image back
/// to the page.
nonisolated struct PageImage: Sendable {
    let image: CGImage
    /// Maps a point in the image, from 0 to 1 with the origin at the bottom
    /// left (as Vision reports them), to page coordinates.
    let toPage: CGAffineTransform

    /// Page coordinates for a rectangle Vision reports.
    func pageRect(forNormalized rect: CGRect) -> CGRect {
        rect.applying(toPage)
    }

    /// Draws a page, or part of it, sharp enough for reading its text:
    /// about 200 dots per inch, and no more than 2,400 pixels across.
    static func forReading(_ page: PDFPage, region: CGRect? = nil) -> PageImage? {
        let bounds = page.bounds(for: .cropBox)
        let wanted = (region ?? bounds).intersection(bounds)
        guard !wanted.isNull, wanted.width >= 1, wanted.height >= 1 else { return nil }
        // Where the region lands once the page is turned the way it's shown.
        let transform = page.transform(for: .cropBox)
        let area = wanted.applying(transform)
        let longest = max(area.width, area.height)
        let scale = min(region == nil ? 3 : 4, 2400 / longest)
        let width = max(1, Int((area.width * scale).rounded()))
        let height = max(1, Int((area.height * scale).rounded()))
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        context.saveGState()
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        guard let image = context.makeImage() else { return nil }
        let toArea = CGAffineTransform(a: area.width, b: 0, c: 0, d: area.height, tx: area.minX, ty: area.minY)
        return PageImage(image: image, toPage: toArea.concatenating(transform.inverted()))
    }

    /// A page thumbnail that fits `size` (in pixels), with highlights drawn
    /// the way the reader shows them.
    static func thumbnail(of page: PDFPage, fitting size: CGSize, highlights: [HighlightSnapshot]) -> CGImage? {
        let transform = page.transform(for: .cropBox)
        let area = page.bounds(for: .cropBox).applying(transform)
        guard area.width > 0, area.height > 0 else { return nil }
        let scale = min(size.width / area.width, size.height / area.height)
        let width = max(1, Int((area.width * scale).rounded()))
        let height = max(1, Int((area.height * scale).rounded()))
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        context.saveGState()
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        // Highlights blend into the page like a marker, as PDFKit draws them.
        context.concatenate(transform)
        context.setBlendMode(.multiply)
        for highlight in highlights {
            let hex = highlight.colorHex
            context.setFillColor(CGColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            ))
            context.fill(highlight.rects)
        }
        return context.makeImage()
    }

    /// An opaque white bitmap, as pages are paper-white.
    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}

/// Telling scanned pages (pictures of text) from pages with real text.
nonisolated enum PageText {
    /// Whether the page has text that can be selected. Scanned pages are
    /// pictures, so they have none (unless the scanner added a text layer).
    static func hasSelectableText(_ page: PDFPage) -> Bool {
        let count = page.numberOfCharacters
        if count == 0 { return false }
        // Long pages surely have some real text; short ones may be only spaces and line breaks.
        if count > 64 { return true }
        return !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A short description of what's drawn on a page: its size, rotation and
    /// the images on it (a scan is one image per page). Adding highlights
    /// doesn't change it, but replacing the scan does, so text read off the
    /// page earlier can be reused only while the fingerprint matches.
    static func fingerprint(of page: PDFPage) -> String {
        guard let ref = page.pageRef, let dictionary = ref.dictionary else { return "" }
        var parts = ["\(ref.getBoxRect(.mediaBox))", "r\(ref.rotationAngle)"]

        var resources: CGPDFDictionaryRef?
        var images: CGPDFDictionaryRef?
        var found: [String] = []
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
           CGPDFDictionaryGetDictionary(resources, "XObject", &images), let images {
            CGPDFDictionaryApplyBlock(images, { _, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream, let info = CGPDFStreamGetDictionary(stream) {
                    var width: CGPDFInteger = 0, height: CGPDFInteger = 0, length: CGPDFInteger = 0
                    CGPDFDictionaryGetInteger(info, "Width", &width)
                    CGPDFDictionaryGetInteger(info, "Height", &height)
                    CGPDFDictionaryGetInteger(info, "Length", &length)
                    found.append("\(width)x\(height)/\(length)")
                }
                return true
            }, nil)
        }
        // PDFKit rewrites a page's drawing instructions when it saves (the
        // images it keeps as they are), so those only count without images.
        guard found.isEmpty else { return (parts + found.sorted()).joined(separator: ";") }

        var contents: CGPDFStreamRef?
        var contentArray: CGPDFArrayRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &contents), let contents {
            parts.append(digest(of: contents))
        } else if CGPDFDictionaryGetArray(dictionary, "Contents", &contentArray), let contentArray {
            for item in 0..<CGPDFArrayGetCount(contentArray) {
                var stream: CGPDFStreamRef?
                if CGPDFArrayGetStream(contentArray, item, &stream), let stream { parts.append(digest(of: stream)) }
            }
        }
        return parts.joined(separator: ";")
    }

    /// The length and a checksum of a page's drawing instructions (tiny
    /// for a scanned page: "draw this image over the page").
    private static func digest(of stream: CGPDFStreamRef) -> String {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return "?" }
        // FNV-1a: stable between launches, unlike Swift's hashValue.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data.prefix(65_536) {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "\(data.count):\(String(hash, radix: 16))"
    }
}
