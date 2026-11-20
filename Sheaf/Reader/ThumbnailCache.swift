import AppKit
import PDFKit

/// Page thumbnails already drawn, shared by all open PDFs, so scrolling
/// back and returning from the library show them at once. The system
/// empties it when memory runs low.
enum ThumbnailCache {
    struct Key: Hashable {
        /// Which open PDF (each reader has its own ID).
        let document: UUID
        let page: Int
        /// In pixels.
        let width: Int
        let height: Int
        /// Changes when the page's highlights do, so the thumbnail is drawn again.
        let highlights: Int

        fileprivate var name: NSString {
            "\(document.uuidString)/\(page)/\(width)x\(height)/\(highlights)" as NSString
        }
    }

    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // About 400 thumbnails.
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(for key: Key) -> NSImage? {
        images.object(forKey: key.name)
    }

    static func store(_ image: NSImage, for key: Key) {
        images.setObject(image, forKey: key.name, cost: key.width * key.height * 4)
    }
}

extension ReaderModel {
    /// How big a page's thumbnail is in the page strip, in points: 108 wide
    /// and at most 160 tall.
    func thumbnailSize(forPage index: Int) -> CGSize {
        guard let page = document.page(at: index) else { return CGSize(width: 108, height: 140) }
        var bounds = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { bounds = CGSize(width: bounds.height, height: bounds.width) }
        guard bounds.width > 0 else { return CGSize(width: 108, height: 140) }
        let width: CGFloat = 108
        return CGSize(width: width, height: min(160, width * bounds.height / bounds.width))
    }

    /// The cache key for a page's thumbnail as it looks now.
    func thumbnailKey(forPage index: Int) -> ThumbnailCache.Key {
        let size = thumbnailSize(forPage: index)
        var hasher = Hasher()
        for record in highlights where record.pageIndex == index {
            hasher.combine(record.id)
            hasher.combine(record.kindRaw)
        }
        return ThumbnailCache.Key(
            document: thumbnailCacheID, page: index,
            // Drawn at twice the size, for Retina screens.
            width: Int(size.width * 2), height: Int(size.height * 2),
            highlights: hasher.finalize()
        )
    }

    /// The thumbnail if it's already drawn.
    func cachedThumbnail(forPage index: Int) -> NSImage? {
        ThumbnailCache.image(for: thumbnailKey(forPage: index))
    }

    /// The page's thumbnail, drawn in the background (from the reader's
    /// second copy of the PDF) unless it's in the cache. Nil if it's no
    /// longer needed.
    func thumbnail(forPage index: Int) async -> NSImage? {
        let key = thumbnailKey(forPage: index)
        if let cached = ThumbnailCache.image(for: key) { return cached }
        let pixels = CGSize(width: key.width, height: key.height)
        let points = thumbnailSize(forPage: index)

        let image: NSImage
        let marks = highlights.filter { $0.pageIndex == index }.map(HighlightSnapshot.init)
        switch await renderer.thumbnail(ofPage: index, fitting: pixels, highlights: marks) {
        case .image(let drawn):
            image = NSImage(cgImage: drawn, size: points)
        case .skipped:
            return nil
        case .unavailable:
            // A PDF with a password: only the copy on screen is unlocked,
            // so draw from it here, as before.
            guard !Task.isCancelled, let page = document.page(at: index) else { return nil }
            image = page.thumbnail(of: pixels, for: .cropBox)
        }
        ThumbnailCache.store(image, for: key)
        return image
    }
}
