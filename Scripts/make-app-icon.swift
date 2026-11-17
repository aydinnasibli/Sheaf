import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the icon on a 1024-point canvas (origin bottom-left), scaled to `size`.
func render(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon shape: 824-point rounded square, centered, with a soft drop shadow.
    // Shadows are drawn in pixels, not in the scaled canvas, so their sizes are multiplied by `s`.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s, color: color(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x161616)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(tilePath); ctx.setStrokeColor(color(0xFFFFFF, 0.08)); ctx.setLineWidth(4); ctx.strokePath()

    // A sheaf of pages: four sheets in the highlighter colors fanned out behind
    // the white page you're reading, all turning around one point below them.
    let sheet = CGRect(x: 362, y: 312, width: 300, height: 440)
    let pivot = CGPoint(x: 512, y: 252)
    let sheets: [(degrees: CGFloat, fill: UInt32)] = [
        (22, 0xFFD43B), (-22, 0x8CE99A), (11, 0xFF8FAB), (-11, 0x74C0FC), (0, 0xF7F7F5)
    ]
    for (degrees, fill) in sheets {
        var turn = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -pivot.x, y: -pivot.y)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 18 * s, color: color(0x000000, 0.3))
        ctx.addPath(CGPath(roundedRect: sheet, cornerWidth: 28, cornerHeight: 28, transform: &turn))
        ctx.setFillColor(color(fill)); ctx.fillPath()
        ctx.restoreGState()
    }

    // Lines of text on the front page.
    let lines: [(y: CGFloat, width: CGFloat)] = [(666, 204), (610, 160), (554, 204), (498, 120)]
    for line in lines {
        let rect = CGRect(x: 410, y: line.y, width: line.width, height: 22)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.setFillColor(color(0xCFCFCB)); ctx.fillPath()
    }

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for size in [16, 32, 64, 128, 256, 512, 1024] {
    try! render(size: size).write(to: out.appending(path: "icon_\(size).png"))
}
print("rendered")
