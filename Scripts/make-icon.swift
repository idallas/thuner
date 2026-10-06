// Renders the app icon: a vinyl record whose label is a tuner dial, needle centred ("in tune").
//   swift Scripts/make-icon.swift            writes Resources/AppIcon.icns (and build/icon-1024.png to look at)
import AppKit

let size: CGFloat = 1024
let orange = NSColor(srgbRed: 1.0, green: 0.50, blue: 0.13, alpha: 1)
let cream = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.86, alpha: 1)

func render() -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let ctx = NSGraphicsContext.current!.cgContext

        // macOS icon grid: 824pt body centred in 1024, continuous-corner rounded rect.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
        bodyPath.fill()
        ctx.restoreGState()

        ctx.saveGState()
        bodyPath.addClip()
        NSGradient(colors: [
            NSColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 1),
            NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1),
        ])!.draw(in: body, angle: -90)

        // The record.
        let c = CGPoint(x: 512, y: 512)
        let recordR: CGFloat = 352
        let record = NSBezierPath(ovalIn: CGRect(x: c.x - recordR, y: c.y - recordR, width: recordR * 2, height: recordR * 2))
        NSColor(white: 0.04, alpha: 1).setFill()
        record.fill()

        // Grooves.
        for i in 0..<14 {
            let r = recordR - 18 - CGFloat(i) * 15
            guard r > 160 else { break }
            let groove = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            groove.lineWidth = i % 4 == 3 ? 3 : 1.5
            NSColor(white: i % 4 == 3 ? 0.16 : 0.11, alpha: 1).setStroke()
            groove.stroke()
        }

        // Sheen: two opposed light wedges, like light catching vinyl.
        ctx.saveGState()
        record.addClip()
        for angle in [CGFloat(35), 215] {
            let wedge = NSBezierPath()
            wedge.move(to: c)
            wedge.appendArc(withCenter: c, radius: recordR, startAngle: angle - 14, endAngle: angle + 14)
            wedge.close()
            NSColor(white: 1, alpha: 0.07).setFill()
            wedge.fill()
        }
        ctx.restoreGState()

        // Label.
        let labelR: CGFloat = 158
        let label = NSBezierPath(ovalIn: CGRect(x: c.x - labelR, y: c.y - labelR, width: labelR * 2, height: labelR * 2))
        NSGradient(colors: [orange.blended(withFraction: 0.15, of: .white)!, orange.blended(withFraction: 0.12, of: .black)!])!
            .draw(in: label, angle: -90)

        // Tuner scale on the label: ticks along an arc over the top, the centre one long.
        let pivot = CGPoint(x: c.x, y: c.y - 62)
        let scaleR: CGFloat = 168
        ctx.saveGState()
        label.addClip()
        for i in -5...5 {
            let a = (90 - CGFloat(i) * 11) * .pi / 180
            let long = i == 0
            let inner = scaleR - (long ? 46 : (i % 2 == 0 ? 30 : 20))
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: pivot.x + cos(a) * inner, y: pivot.y + sin(a) * inner))
            tick.line(to: CGPoint(x: pivot.x + cos(a) * (scaleR - 6), y: pivot.y + sin(a) * (scaleR - 6)))
            tick.lineWidth = long ? 9 : 6
            tick.lineCapStyle = .round
            (long ? cream : cream.withAlphaComponent(0.75)).setStroke()
            tick.stroke()
        }
        ctx.restoreGState()

        // Needle, pointing straight up: in tune.
        let needle = NSBezierPath()
        needle.move(to: CGPoint(x: pivot.x - 9, y: pivot.y))
        needle.line(to: CGPoint(x: pivot.x, y: pivot.y + scaleR - 14))
        needle.line(to: CGPoint(x: pivot.x + 9, y: pivot.y))
        needle.close()
        NSColor(white: 0.08, alpha: 1).setFill()
        needle.fill()

        // Spindle hole doubling as the needle's pivot.
        let hole = NSBezierPath(ovalIn: CGRect(x: pivot.x - 20, y: pivot.y - 20, width: 40, height: 40))
        NSColor(white: 0.08, alpha: 1).setFill()
        hole.fill()
        let holeHighlight = NSBezierPath(ovalIn: CGRect(x: pivot.x - 8, y: pivot.y - 8, width: 16, height: 16))
        cream.withAlphaComponent(0.9).setFill()
        holeHighlight.fill()

        ctx.restoreGState()

        // Hairline edge.
        NSColor(white: 1, alpha: 0.10).setStroke()
        bodyPath.lineWidth = 2
        bodyPath.stroke()
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let image = render()
try png(image, pixels: 1024).write(to: root.appendingPathComponent("build/icon-1024.png"))
for base in [16, 32, 128, 256, 512] {
    try png(image, pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(image, pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
