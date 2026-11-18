// Draws the app icon: swift scripts/make-icon.swift && iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.12
    let back = NSRect(x: inset + s * 0.06, y: inset - s * 0.02, width: s - inset * 2, height: s - inset * 2)
    NSColor(srgbRed: 0.68, green: 0.85, blue: 1, alpha: 1).setFill()
    NSBezierPath(roundedRect: back, xRadius: s * 0.05, yRadius: s * 0.05).fill()
    let front = NSRect(x: inset, y: inset + s * 0.02, width: s - inset * 2, height: s - inset * 2)
    let shadow = NSShadow(); shadow.shadowBlurRadius = s * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    NSColor(srgbRed: 1, green: 0.93, blue: 0.45, alpha: 1).setFill()
    NSBezierPath(roundedRect: front, xRadius: s * 0.05, yRadius: s * 0.05).fill()
    NSShadow().set()
    NSColor(white: 0, alpha: 0.25).setFill()
    for i in 0..<4 {
        let y = front.maxY - s * 0.2 - CGFloat(i) * s * 0.13
        NSBezierPath(roundedRect: NSRect(x: front.minX + s * 0.1, y: y, width: front.width * (i == 3 ? 0.4 : 0.7), height: s * 0.04),
                     xRadius: s * 0.02, yRadius: s * 0.02).fill()
    }
    let plus = NSString(string: "+")
    plus.draw(at: NSPoint(x: front.maxX - s * 0.27, y: front.minY + s * 0.02),
              withAttributes: [.font: NSFont.systemFont(ofSize: s * 0.28, weight: .heavy),
                               .foregroundColor: NSColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1)])
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes {
    if size <= 512 { try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try! render(size).write(to: out.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
