// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let s = CGFloat(pixels)
    let tile = NSRect(x: s * 0.09, y: s * 0.09, width: s * 0.82, height: s * 0.82)
    let background = NSBezierPath(roundedRect: tile, xRadius: s * 0.185, yRadius: s * 0.185)
    NSGradient(colors: [NSColor(red: 0.22, green: 0.60, blue: 0.99, alpha: 1), NSColor(red: 0.09, green: 0.27, blue: 0.78, alpha: 1)])!
        .draw(in: background, angle: -90)

    // A clock face whose hands sweep a filled "tracked time" wedge.
    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = s * 0.25
    let wedge = NSBezierPath()
    wedge.move(to: center)
    wedge.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -30, clockwise: true)
    wedge.close()
    NSColor.white.withAlphaComponent(0.35).setFill()
    wedge.fill()

    NSColor.white.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    ring.lineWidth = s * 0.05
    ring.stroke()

    let hands = NSBezierPath()
    hands.lineWidth = s * 0.05
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.move(to: NSPoint(x: center.x, y: center.y + radius * 0.62))
    hands.line(to: center)
    hands.line(to: NSPoint(x: center.x + radius * 0.52, y: center.y - radius * 0.30))
    hands.stroke()

    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
