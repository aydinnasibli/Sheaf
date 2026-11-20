import AppKit
import Vision

/// Whether this Mac can read text in pictures (Vision's text recognition).
/// Build machines without it, like some virtual Macs, skip the tests that
/// need it instead of failing them.
enum TextRecognitionCheck {
    static let isAvailable: Bool = {
        let size = CGSize(width: 600, height: 160)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(.white)
        context.fill(CGRect(origin: .zero, size: size))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSAttributedString(string: "Reading test", attributes: [.font: NSFont.systemFont(ofSize: 56)])
            .draw(at: CGPoint(x: 30, y: 50))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return false }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return false
        }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        return text.localizedCaseInsensitiveContains("reading")
    }()
}
