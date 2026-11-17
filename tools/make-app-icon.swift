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
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x161616)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(tilePath); ctx.setStrokeColor(color(0xFFFFFF, 0.08)); ctx.setLineWidth(4); ctx.strokePath()

    // The page.
    let page = CGRect(x: 262, y: 196, width: 500, height: 632)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(color(0xF7F7F5)); ctx.fillPath()
    ctx.restoreGState()

    // Text lines, some highlighted in the four Sheaf colors.
    let left: CGFloat = 322, lineH: CGFloat = 22
    let rows: [(width: CGFloat, highlight: UInt32?)] = [
        (380, 0xFFD43B), (300, nil), (380, 0xFF8FAB), (340, nil), (380, 0x74C0FC), (260, 0x8CE99A)
    ]
    var y: CGFloat = 724
    for row in rows {
        if let hl = row.highlight {
            let band = CGRect(x: left - 16, y: y - 24, width: row.width + 32, height: lineH + 48)
            ctx.addPath(CGPath(roundedRect: band, cornerWidth: 20, cornerHeight: 20, transform: nil))
            ctx.setFillColor(color(hl)); ctx.fillPath()
        }
        let line = CGRect(x: left, y: y, width: row.width, height: lineH)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.setFillColor(color(row.highlight == nil ? 0xC9C9C6 : 0x1E1E1E, row.highlight == nil ? 1 : 0.82)); ctx.fillPath()
        y -= 92
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
