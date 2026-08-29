// Draws the Perch mark — the island silhouette hanging from a bezel line, traced by a
// focus session — and writes the app icon and the README logo.
//
//   swift Tools/MakeIcon.swift
import AppKit
import Foundation

let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Assets")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

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

/// The blue session hairline: down the left shoulder, across the bottom, part way up.
func tracePath(rect: CGRect, shoulder s: CGFloat, bottom b: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: rect.minX + s, y: rect.maxY))
    p.line(to: CGPoint(x: rect.minX + s, y: rect.minY + b))
    p.curve(to: CGPoint(x: rect.minX + s + b, y: rect.minY),
            controlPoint1: CGPoint(x: rect.minX + s, y: rect.minY),
            controlPoint2: CGPoint(x: rect.minX + s, y: rect.minY))
    p.line(to: CGPoint(x: rect.maxX - s - b - (rect.width * 0.20), y: rect.minY))
    return p
}

func render(size n: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: n, height: n))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    ctx.setAllowsAntialiasing(true)

    // Ground: a squircle-ish rounded square with a top-lit gradient.
    let ground = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: n, height: n),
                              xRadius: n * 0.2237, yRadius: n * 0.2237)
    ground.addClip()
    // Light at the top, dark at the bottom, so a pure-black island still reads.
    let gradient = NSGradient(colors: [NSColor(srgbRed: 0.180, green: 0.196, blue: 0.235, alpha: 1),
                                       NSColor(srgbRed: 0.043, green: 0.051, blue: 0.067, alpha: 1)])
    gradient?.draw(in: NSRect(x: 0, y: 0, width: n, height: n), angle: -90)

    // The bezel the island hangs from.
    let bezelY = n * 0.70
    NSColor(white: 1, alpha: 0.10).setStroke()
    let bezel = NSBezierPath()
    bezel.lineWidth = max(1, n * 0.006)
    bezel.move(to: CGPoint(x: n * 0.06, y: bezelY))
    bezel.line(to: CGPoint(x: n * 0.94, y: bezelY))
    bezel.stroke()

    let body = CGRect(x: n * 0.135, y: n * 0.335, width: n * 0.73, height: n * 0.365)
    let shoulder = n * 0.055
    let bottom = n * 0.135

    // Body, with a soft drop shadow so it sits above the ground.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -n * 0.02), blur: n * 0.06,
                  color: NSColor(white: 0, alpha: 0.55).cgColor)
    NSColor(srgbRed: 0.008, green: 0.008, blue: 0.012, alpha: 1).setFill()
    islandPath(rect: body, shoulder: shoulder, bottom: bottom).fill()
    ctx.restoreGState()

    let edge = islandPath(rect: body, shoulder: shoulder, bottom: bottom)
    edge.lineWidth = max(1, n * 0.007)
    NSColor(white: 1, alpha: 0.22).setStroke()
    edge.stroke()

    // Session hairline.
    let inset = n * 0.028
    let traceRect = body.insetBy(dx: inset, dy: inset)
    let trace = tracePath(rect: traceRect, shoulder: shoulder * 0.8, bottom: bottom * 0.75)
    trace.lineWidth = n * 0.026
    trace.lineCapStyle = .round
    trace.lineJoinStyle = .round
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: n * 0.05,
                  color: NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 0.9).cgColor)
    NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1).setStroke()
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

// README logo.
writePNG(render(size: 1024), to: out.appendingPathComponent("logo.png"), pixels: 1024)

// Icon set.
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
