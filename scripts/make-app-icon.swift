// Renders the app icon designed on the canvas (A3 "Icona"): a white zipper X on a blue gradient,
// into App/Xipper/Assets.xcassets/AppIcon.appiconset. Below 32 pt the teeth are dropped (only the X).
// Usage: swift scripts/make-app-icon.swift
import AppKit

let out = "App/Xipper/Assets.xcassets/AppIcon.appiconset"

/// The glyph in the canvas' 40×40 SVG coordinates (y down): the X and the zipper teeth.
let xStrokes: [(CGPoint, CGPoint)] = [(.init(x: 8, y: 6), .init(x: 32, y: 34)), (.init(x: 32, y: 6), .init(x: 8, y: 34))]
let teeth: [(CGPoint, CGPoint)] = [(17, 11, 12), (23, 11, 28), (15, 16, 10), (25, 16, 30), (15, 24, 10), (25, 24, 30), (17, 29, 12), (23, 29, 28)]
    .map { (CGPoint(x: $0.0, y: $0.1), CGPoint(x: $0.2, y: $0.1)) }

func render(_ px: Int, points: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body, centred, continuous corners (~185/1024).
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: size * 185 / 1024, yRadius: size * 185 / 1024)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 10 / 1024)
    shadow.shadowBlurRadius = size * 24 / 1024
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Background layer: #4AA3FF (top left) → #0A57D4 (bottom right).
    NSGradient(colors: [NSColor(srgbRed: 0x4A / 255, green: 0xA3 / 255, blue: 1, alpha: 1),
                        NSColor(srgbRed: 0x0A / 255, green: 0x57 / 255, blue: 0xD4 / 255, alpha: 1)])!.draw(in: path, angle: -75)
    // Thin top highlight of the glass edge.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.maxY - body.height * 0.12, width: body.width, height: body.height * 0.12), angle: 270)
    NSGraphicsContext.restoreGraphicsState()
    // Glyph layer: inset 18% of the body, white round-capped strokes.
    let box = body.insetBy(dx: body.width * 0.18, dy: body.height * 0.18)
    let k = box.width / 40
    func point(_ p: CGPoint) -> NSPoint { NSPoint(x: box.minX + p.x * k, y: box.maxY - p.y * k) }
    func stroke(_ lines: [(CGPoint, CGPoint)], width: CGFloat) {
        let b = NSBezierPath()
        for (a, c) in lines { b.move(to: point(a)); b.line(to: point(c)) }
        b.lineWidth = width * k
        b.lineCapStyle = .round
        b.stroke()
    }
    NSColor.white.setStroke()
    stroke(xStrokes, width: points < 32 ? 6 : 5)
    if points >= 32 { stroke(teeth, width: 2.4) }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let file = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try! render(pt * scale, points: pt).write(to: URL(fileURLWithPath: "\(out)/\(file)"))
        images.append(#"{"idiom":"mac","size":"\#(pt)x\#(pt)","scale":"\#(scale)x","filename":"\#(file)"}"#)
    }
}
let contents = #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
try! contents.write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
try! #"{"info":{"author":"xcode","version":1}}"#.write(toFile: "App/Xipper/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
print("icon written to \(out)")
