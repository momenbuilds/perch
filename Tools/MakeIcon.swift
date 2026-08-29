// Draws the Perch mark — the island hanging from the bezel, wrapped by a focus session —
// and writes the app icon and the README logo.
//
//   swift Tools/MakeIcon.swift && iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
import AppKit
import Foundation

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Assets")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1)

/// The island silhouette: flush top edge, concave shoulders, deep rounded bottom.
/// `rect.maxY` is the bezel the shape hangs from.
func islandPath(rect: CGRect, shoulder s: CGFloat, bottom b: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    p.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
    p.curve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - s),
            controlPoint1: CGPoint(x: rect.maxX - s, y: rect.maxY),
            controlPoint2: CGPoint(x: rect.maxX - s, y: rect.maxY))
    p.line(to: CGPoint(x: rect.maxX - s, y: rect.minY + b))
    p.curve(to: CGPoint(x: rect.maxX - s - b, y: rect.minY),
            controlPoint1: CGPoint(x: rect.maxX - s, y: rect.minY),
            controlPoint2: CGPoint(x: rect.maxX - s, y: rect.minY))
    p.line(to: CGPoint(x: rect.minX + s + b, y: rect.minY))
    p.curve(to: CGPoint(x: rect.minX + s, y: rect.minY + b),
            controlPoint1: CGPoint(x: rect.minX + s, y: rect.minY),
            controlPoint2: CGPoint(x: rect.minX + s, y: rect.minY))
    p.line(to: CGPoint(x: rect.minX + s, y: rect.maxY - s))
    p.curve(to: CGPoint(x: rect.minX, y: rect.maxY),
            controlPoint1: CGPoint(x: rect.minX + s, y: rect.maxY),
            controlPoint2: CGPoint(x: rect.minX + s, y: rect.maxY))
    p.close()
    return p
}

/// The session hairline, hugging the inside of the body: down the left, across the
/// bottom, and part of the way back up.
func tracePath(rect: CGRect, shoulder s: CGFloat, bottom b: CGFloat, progress: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: rect.minX + s, y: rect.maxY))
    p.line(to: CGPoint(x: rect.minX + s, y: rect.minY + b))
    p.curve(to: CGPoint(x: rect.minX + s + b, y: rect.minY),
            controlPoint1: CGPoint(x: rect.minX + s, y: rect.minY),
            controlPoint2: CGPoint(x: rect.minX + s, y: rect.minY))
    let span = (rect.maxX - s - b) - (rect.minX + s + b)
    p.line(to: CGPoint(x: rect.minX + s + b + span * progress, y: rect.minY))
    return p
}

func render(size n: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: n, height: n))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    ctx.setAllowsAntialiasing(true)

    let ground = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: n, height: n),
                              xRadius: n * 0.2237, yRadius: n * 0.2237)
    ground.addClip()

    // Screen: dark, lit from the top.
    NSGradient(colors: [NSColor(srgbRed: 0.114, green: 0.125, blue: 0.149, alpha: 1),
                        NSColor(srgbRed: 0.035, green: 0.039, blue: 0.051, alpha: 1)])?
        .draw(in: NSRect(x: 0, y: 0, width: n, height: n), angle: -90)

    // Bezel band across the top, the edge the island is welded to.
    let bezelHeight = n * 0.185
    NSGradient(colors: [NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1),
                        NSColor(srgbRed: 0.106, green: 0.118, blue: 0.145, alpha: 1)])?
        .draw(in: NSRect(x: 0, y: n - bezelHeight, width: n, height: bezelHeight), angle: -90)
    NSColor(white: 1, alpha: 0.07).setFill()
    NSRect(x: 0, y: n - bezelHeight - n * 0.004, width: n, height: n * 0.004).fill()

    let body = CGRect(x: n * 0.155, y: n * 0.375,
                      width: n * 0.69, height: n - bezelHeight - n * 0.375)
    let shoulder = n * 0.05
    let bottom = n * 0.14

    // Ambient glow beneath, as if a session were running.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -n * 0.03), blur: n * 0.10,
                  color: accent.withAlphaComponent(0.38).cgColor)
    NSColor(srgbRed: 0.006, green: 0.006, blue: 0.01, alpha: 1).setFill()
    islandPath(rect: body, shoulder: shoulder, bottom: bottom).fill()
    ctx.restoreGState()

    let edge = islandPath(rect: body, shoulder: shoulder, bottom: bottom)
    edge.lineWidth = max(1, n * 0.0075)
    NSColor(white: 1, alpha: 0.26).setStroke()
    edge.stroke()

    // Session hairline.
    let inset = n * 0.028
    let traceRect = body.insetBy(dx: inset, dy: inset)
    let trace = tracePath(rect: traceRect, shoulder: shoulder * 0.75,
                          bottom: bottom * 0.72, progress: 0.62)
    trace.lineWidth = n * 0.026
    trace.lineCapStyle = .round
    trace.lineJoinStyle = .round
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: n * 0.055, color: accent.withAlphaComponent(0.95).cgColor)
    accent.setStroke()
    trace.stroke()
    ctx.restoreGState()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])!.write(to: url)
}

writePNG(render(size: 1024), to: out.appendingPathComponent("logo.png"), pixels: 1024)

let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                        (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    writePNG(render(size: CGFloat(pixels)), to: iconset.appendingPathComponent(name), pixels: pixels)
}
print("wrote Assets/logo.png and Assets/AppIcon.iconset")
