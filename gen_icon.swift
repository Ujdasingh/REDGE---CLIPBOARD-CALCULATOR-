import Foundation
import AppKit

extension NSColor {
    static func hex(_ rgb: Int, alpha: CGFloat = 1) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

let outDir = URL(fileURLWithPath:
    CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Redge.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func fill(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawIconContents() {
    let bgRect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 228, yRadius: 228)
    NSGraphicsContext.current!.saveGraphicsState()
    bgPath.addClip()
    let bgGrad = NSGradient(colors: [.hex(0x14b8a6), .hex(0x0f3a36)])!
    bgGrad.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 1024, y: 1024), options: [])
    NSGraphicsContext.current!.restoreGraphicsState()

    let hpath = NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 1012, height: 1012),
                             xRadius: 224, yRadius: 224)
    hpath.lineWidth = 2
    NSColor.white.withAlphaComponent(0.08).setStroke()
    hpath.stroke()

    fill(NSRect(x: 120, y: 352, width: 540, height: 420), radius: 34,
         color: NSColor.black.withAlphaComponent(0.18))
    fill(NSRect(x: 120, y: 340, width: 540, height: 420), radius: 34,
         color: .hex(0x5eead4, alpha: 0.55))

    fill(NSRect(x: 160, y: 304, width: 540, height: 490), radius: 36,
         color: NSColor.black.withAlphaComponent(0.22))
    fill(NSRect(x: 160, y: 290, width: 540, height: 490), radius: 36,
         color: .hex(0x99f6e4))

    fill(NSRect(x: 200, y: 246, width: 540, height: 600), radius: 38,
         color: NSColor.black.withAlphaComponent(0.28))

    let clipboardRect = NSRect(x: 200, y: 230, width: 540, height: 600)
    let clipboardPath = NSBezierPath(roundedRect: clipboardRect, xRadius: 38, yRadius: 38)
    NSGraphicsContext.current!.saveGraphicsState()
    clipboardPath.addClip()
    let paperGrad = NSGradient(colors: [.white, .hex(0xccfbf1)])!
    paperGrad.draw(from: NSPoint(x: 0, y: 230), to: NSPoint(x: 0, y: 830), options: [])
    NSGraphicsContext.current!.restoreGraphicsState()

    fill(NSRect(x: 370, y: 190, width: 200, height: 92), radius: 22, color: .hex(0x475569))
    fill(NSRect(x: 410, y: 168, width: 120, height: 42), radius: 12, color: .hex(0x64748b))

    let teal = NSColor.hex(0x0d9488)
    fill(NSRect(x: 260, y: 360, width: 380, height: 24), radius: 6, color: teal.withAlphaComponent(0.65))
    fill(NSRect(x: 260, y: 420, width: 320, height: 24), radius: 6, color: teal.withAlphaComponent(0.55))
    fill(NSRect(x: 260, y: 480, width: 400, height: 24), radius: 6, color: teal.withAlphaComponent(0.50))
    fill(NSRect(x: 260, y: 540, width: 280, height: 24), radius: 6, color: teal.withAlphaComponent(0.45))
    fill(NSRect(x: 260, y: 600, width: 340, height: 24), radius: 6, color: teal.withAlphaComponent(0.40))

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 800, y: 480))
    arrow.line(to: NSPoint(x: 920, y: 560))
    arrow.line(to: NSPoint(x: 800, y: 640))
    arrow.lineWidth = 26
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.hex(0xccfbf1).setStroke()
    arrow.stroke()
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true

    let scale = CGFloat(size) / 1024.0
    ctx.cgContext.translateBy(x: 0, y: CGFloat(size))
    ctx.cgContext.scaleBy(x: scale, y: -scale)

    drawIconContents()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (filename, size) in sizes {
    let rep = drawIcon(size: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        print("Failed to encode \(filename)")
        continue
    }
    let url = outDir.appendingPathComponent(filename)
    do {
        try png.write(to: url)
        print("Wrote \(filename) (\(size)x\(size))")
    } catch {
        print("Failed to write \(filename): \(error)")
    }
}
