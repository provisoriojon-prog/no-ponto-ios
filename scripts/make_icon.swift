// Original No Ponto artwork. AppKit vector drawing, no downloaded assets.
// Usage: swift scripts/make_icon.swift [NoPonto/Assets.xcassets]
import AppKit
import Foundation

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func rounded(_ rect: NSRect, _ radius: CGFloat, _ fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func artwork() {
    let canvas = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGradient(starting: color(0x071D38), ending: color(0x104B6E))!.draw(in: canvas, angle: 50)

    // Two curved road traces give the mark its own transit-map identity.
    let road = NSBezierPath()
    road.move(to: NSPoint(x: -80, y: 130))
    road.curve(to: NSPoint(x: 1060, y: 900), controlPoint1: NSPoint(x: 360, y: 80), controlPoint2: NSPoint(x: 640, y: 1020))
    road.lineWidth = 42
    road.lineCapStyle = .round
    color(0x69DAD2, alpha: 0.11).setStroke()
    road.stroke()
    let secondRoad = NSBezierPath()
    secondRoad.move(to: NSPoint(x: -40, y: 840))
    secondRoad.curve(to: NSPoint(x: 1070, y: 220), controlPoint1: NSPoint(x: 400, y: 1050), controlPoint2: NSPoint(x: 780, y: 30))
    secondRoad.lineWidth = 12
    color(0xDAFFFF, alpha: 0.08).setStroke()
    secondRoad.stroke()

    // Bold location pin with a generous silhouette for small Home Screen sizes.
    let pin = NSBezierPath()
    pin.move(to: NSPoint(x: 512, y: 138))
    pin.curve(to: NSPoint(x: 244, y: 596), controlPoint1: NSPoint(x: 410, y: 278), controlPoint2: NSPoint(x: 244, y: 413))
    pin.curve(to: NSPoint(x: 512, y: 877), controlPoint1: NSPoint(x: 244, y: 758), controlPoint2: NSPoint(x: 360, y: 877))
    pin.curve(to: NSPoint(x: 780, y: 596), controlPoint1: NSPoint(x: 664, y: 877), controlPoint2: NSPoint(x: 780, y: 758))
    pin.curve(to: NSPoint(x: 512, y: 138), controlPoint1: NSPoint(x: 780, y: 413), controlPoint2: NSPoint(x: 614, y: 278))
    pin.close()
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x001020, alpha: 0.35)
    shadow.shadowBlurRadius = 35
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    color(0x25D7C5).setFill()
    pin.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x16B6C6), ending: color(0x53E6CA))!.draw(in: pin, angle: 85)

    // A front-facing bus, designed here from simple geometric primitives.
    rounded(NSRect(x: 359, y: 402, width: 306, height: 354), 57, color(0xF4FEFF))
    rounded(NSRect(x: 384, y: 535, width: 256, height: 154), 26, color(0x0A3150))
    rounded(NSRect(x: 446, y: 714, width: 132, height: 14), 7, color(0x08788E))
    // A subtle windscreen highlight preserves contrast without fine detail.
    let glass = NSBezierPath()
    glass.move(to: NSPoint(x: 404, y: 668))
    glass.line(to: NSPoint(x: 481, y: 668))
    glass.line(to: NSPoint(x: 424, y: 556))
    glass.line(to: NSPoint(x: 404, y: 556))
    glass.close()
    color(0x58C4D0, alpha: 0.19).setFill()
    glass.fill()
    rounded(NSRect(x: 394, y: 447, width: 49, height: 37), 16, color(0x1195A4))
    rounded(NSRect(x: 581, y: 447, width: 49, height: 37), 16, color(0x1195A4))
    rounded(NSRect(x: 474, y: 455, width: 76, height: 15), 7, color(0xBDDDE1))
    rounded(NSRect(x: 390, y: 378, width: 48, height: 57), 14, color(0x0A3150))
    rounded(NSRect(x: 586, y: 378, width: 48, height: 57), 14, color(0x0A3150))
    rounded(NSRect(x: 332, y: 572, width: 26, height: 73), 10, color(0xF4FEFF))
    rounded(NSRect(x: 666, y: 572, width: 26, height: 73), 10, color(0xF4FEFF))
}

func render(size: Int, destination: URL) throws {
    // No alpha channel: App Store and Home Screen icon assets must be opaque.
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "NoPontoIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    artwork()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "NoPontoIcon", code: 2)
    }
    try data.write(to: destination)
}

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "NoPonto/Assets.xcassets", isDirectory: true)
let appIcon = directory.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
let info: [String: Any] = ["author": "No Ponto", "version": 1]
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
var images: [[String: String]] = []
let sizes: [(String, Double, [Int])] = [
    ("iphone", 20, [2, 3]), ("iphone", 29, [2, 3]), ("iphone", 40, [2, 3]), ("iphone", 60, [2, 3]),
    ("ipad", 20, [1, 2]), ("ipad", 29, [1, 2]), ("ipad", 40, [1, 2]), ("ipad", 76, [1, 2]), ("ipad", 83.5, [2]),
    ("ios-marketing", 1024, [1])
]
var written = Set<Int>()
for (idiom, points, scales) in sizes {
    for scale in scales {
        let pixels = Int(points * Double(scale))
        let filename = "Icon-\(pixels).png"
        if written.insert(pixels).inserted { try render(size: pixels, destination: appIcon.appendingPathComponent(filename)) }
        let label = points == floor(points) ? String(Int(points)) : String(points)
        images.append(["idiom": idiom, "size": "\(label)x\(label)", "scale": "\(scale)x", "filename": filename])
    }
}
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys]).write(to: appIcon.appendingPathComponent("Contents.json"))
print("No Ponto: original opaque icon generated in \(written.count) pixel sizes at \(appIcon.path)")
