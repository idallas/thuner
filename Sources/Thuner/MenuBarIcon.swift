import AppKit

/// Menu bar template icons: a tuner gauge whose needle tells you the state. Resting at the left when idle,
/// swinging in while identifying, straight up ("in tune") when a track is confirmed. While playing it can also
/// work as a slow, stepped level meter, like a neon sign: the needle sits on a tick and the ticks up to it
/// are lit.
enum MenuBarIcon {
    enum Kind: Hashable {
        case idle, identifying, playing
        /// Playing, animated: 0 = leftmost tick, `levels - 1` = rightmost.
        case level(Int)
        /// Another Mac (the turntable Mac) is listening: the gauge shows its state, with radio waves beside it.
        case elsewhere(playing: Bool)
        /// Listening is paused: the gauge dimmed, with pause bars beside it, or a "z" for an auto-pause (which
        /// wakes by itself when music starts).
        case paused(auto: Bool)
    }

    static let levels = 7
    private static var cache: [Kind: NSImage] = [:]

    static func image(_ kind: Kind) -> NSImage {
        if let hit = cache[kind] { return hit }
        let image = draw(kind)
        cache[kind] = image
        return image
    }

    /// Angle of tick `i` (0 = rightmost at 40°, 6 = leftmost at 140°).
    private static func tickDegrees(_ i: Int) -> CGFloat { 40 + CGFloat(i) * 50 / 3 }

    private static func draw(_ kind: Kind) -> NSImage {
        let isElsewhere: Bool
        var pausedAuto: Bool?
        let gaugeKind: Kind
        switch kind {
        case .elsewhere(let playing):
            isElsewhere = true
            gaugeKind = playing ? .playing : .identifying
        case .paused(let auto):
            isElsewhere = false
            pausedAuto = auto
            gaugeKind = .idle
        default:
            isElsewhere = false
            gaugeKind = kind
        }
        let wide = isElsewhere || pausedAuto != nil
        let image = NSImage(size: NSSize(width: wide ? 27 : 20, height: 18), flipped: false) { _ in
            if pausedAuto != nil {
                // Dimmed: the gauge at half strength, drawn into a layer so its parts don't add up.
                NSGraphicsContext.current?.cgContext.setAlpha(0.45)
                NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                drawGauge(gaugeKind)
                NSGraphicsContext.current?.cgContext.endTransparencyLayer()
                NSGraphicsContext.current?.cgContext.setAlpha(1)
            } else {
                drawGauge(gaugeKind)
            }
            if isElsewhere { drawWaves(around: CGPoint(x: 20.5, y: 9)) }
            if let auto = pausedAuto {
                if auto { drawSleep(at: CGPoint(x: 21, y: 3)) } else { drawPauseBars(at: CGPoint(x: 21.5, y: 3)) }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = switch kind {
        case .idle: "ThUNER: idle"
        case .identifying: "ThUNER: identifying"
        case .playing, .level: "ThUNER: playing"
        case .elsewhere: "ThUNER: the turntable Mac is listening"
        case .paused(let auto): auto ? "ThUNER: paused until music plays" : "ThUNER: listening paused"
        }
        return image
    }

    /// Two short vertical bars, the pause symbol.
    private static func drawPauseBars(at origin: CGPoint) {
        NSColor.black.set()
        for dx in [CGFloat(0), 3.6] {
            NSBezierPath(roundedRect: CGRect(x: origin.x + dx, y: origin.y, width: 2, height: 8), xRadius: 0.8, yRadius: 0.8).fill()
        }
    }

    /// A small "z", for an auto-pause that wakes by itself.
    private static func drawSleep(at origin: CGPoint) {
        let z = NSBezierPath()
        z.move(to: CGPoint(x: origin.x, y: origin.y + 7))
        z.line(to: CGPoint(x: origin.x + 5, y: origin.y + 7))
        z.line(to: CGPoint(x: origin.x, y: origin.y))
        z.line(to: CGPoint(x: origin.x + 5, y: origin.y))
        z.lineWidth = 1.5
        z.lineCapStyle = .round
        z.lineJoinStyle = .round
        NSColor.black.set()
        z.stroke()
    }

    /// Two short arcs opening to the right, like a broadcast symbol.
    private static func drawWaves(around center: CGPoint) {
        NSColor.black.set()
        for (radius, alpha) in [(CGFloat(3.2), CGFloat(1)), (5.8, 0.7)] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: -45, endAngle: 45)
            arc.lineWidth = 1.4
            arc.lineCapStyle = .round
            NSColor.black.withAlphaComponent(alpha).set()
            arc.stroke()
        }
    }

    private static func drawGauge(_ kind: Kind) {
        let pivot = CGPoint(x: 10, y: 4)

        // Level 0 lights only the leftmost tick; the top level lights them all.
        let litFrom: Int? = if case .level(let l) = kind { levels - 1 - min(max(l, 0), levels - 1) } else { nil }

        // Scale: seven ticks across the top, the centre one longer.
        for i in 0..<levels {
            let a = tickDegrees(i) * .pi / 180
            let inner: CGFloat = i == 3 ? 7.4 : 9.0
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: pivot.x + cos(a) * inner, y: pivot.y + sin(a) * inner))
            tick.line(to: CGPoint(x: pivot.x + cos(a) * 11.6, y: pivot.y + sin(a) * 11.6))
            tick.lineWidth = i == 3 ? 1.8 : 1.4
            tick.lineCapStyle = .round
            let alpha: CGFloat = switch kind {
            case .idle: i == 3 ? 1 : 0.55
            case .level: i >= litFrom! ? 1 : 0.3
            default: 1
            }
            NSColor.black.withAlphaComponent(alpha).set()
            tick.stroke()
        }
        NSColor.black.set()

        let needleDegrees: CGFloat = switch kind {
        case .idle: 148
        case .identifying: 118
        case .playing: 90
        case .level: tickDegrees(litFrom!)
        case .elsewhere: 90  // drawn as .playing or .identifying
        case .paused: 148  // drawn as .idle
        }
        let a = needleDegrees * .pi / 180
        let needle = NSBezierPath()
        needle.move(to: pivot)
        let length: CGFloat = kind == .idle ? 8.5 : 10.5
        needle.line(to: CGPoint(x: pivot.x + cos(a) * length, y: pivot.y + sin(a) * length))
        needle.lineWidth = 1.8
        needle.lineCapStyle = .round
        needle.stroke()

        let r: CGFloat = kind == .idle || kind == .identifying ? 2.1 : 2.6
        let hub = NSBezierPath(ovalIn: CGRect(x: pivot.x - r, y: pivot.y - r, width: r * 2, height: r * 2))
        if kind == .idle {
            hub.lineWidth = 1.3
            hub.stroke()
        } else {
            hub.fill()
        }
    }
}
