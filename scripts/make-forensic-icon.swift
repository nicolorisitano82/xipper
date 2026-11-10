// Draws the Xipper Forensic app icon (App/XipperForensic/Resources/AppIcon.icns):
// a dark blue rounded square with a white shield and check, the macOS icon grid.
//   swift scripts/make-forensic-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = FileManager.default.temporaryDirectory.appendingPathComponent("XipperForensic.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS grid: 824/1024 body, corner radius ~185/1024.
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024,
                                                    color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSGradient(starting: NSColor(red: 0.10, green: 0.22, blue: 0.45, alpha: 1), ending: NSColor(red: 0.03, green: 0.08, blue: 0.20, alpha: 1))!
        .draw(in: path, angle: -90)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 0.07, green: 0.16, blue: 0.34, alpha: 1), .white]))
    if let sym = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + s * 0.01, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)" + (scale == 2 ? "@2x" : "") + ".png"
    try draw(pt * scale).write(to: set.appendingPathComponent(name))
}
let out = root.appendingPathComponent("App/XipperForensic/Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? draw(1024).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("XipperForensic-icon.png"))
print(out.path)
