// Renders Support/AppIcon.icns: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with ~18.5% corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.set()
    NSGradient(starting: NSColor(calibratedRed: 0.985, green: 0.972, blue: 0.945, alpha: 1),
               ending: NSColor(calibratedRed: 0.93, green: 0.905, blue: 0.86, alpha: 1))!.draw(in: path, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // A quiet highlight under the letter — the editor's annotation mark.
    let mark = NSRect(x: body.minX + body.width * 0.24, y: body.minY + body.height * 0.19, width: body.width * 0.52, height: body.height * 0.06)
    NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.30, alpha: 0.55).setFill()
    NSBezierPath(roundedRect: mark, xRadius: mark.height / 2, yRadius: mark.height / 2).fill()

    let base = NSFont.systemFont(ofSize: body.height * 0.72, weight: .regular)
    let serif = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
    let italic = NSFont(descriptor: serif.fontDescriptor.withSymbolicTraits(.italic), size: serif.pointSize) ?? serif
    let text = NSAttributedString(string: "T", attributes: [.font: italic, .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1)])
    let size = text.size()
    text.draw(at: NSPoint(x: body.midX - size.width / 2 - body.width * 0.095, y: body.midY - size.height / 2 + body.height * 0.03))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support")
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try render(1024).write(to: root.appendingPathComponent("AppIcon.png"))
print("wrote \(root.path)/AppIcon.icns")
