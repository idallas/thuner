import AppKit
import SwiftUI
import ThunerCore

/// Reads the stream's numbers about ten times a second while a meter is on screen, and keeps the last 30 seconds
/// of buffer level for the history graph. Only the meters redraw at that rate, not everything watching AppModel.
@MainActor @Observable
final class StreamMeterFeed {
    struct Sample {
        var bufferMs: Double
        var targetMs: Double
        var jitterMs: Double
        /// Audio went missing since the previous sample.
        var dropout: Bool
    }

    private(set) var stats: PlayoutStats?
    private(set) var latency: AudioStreamReceiver.Latency?
    /// The buffer and its target as time spent waiting: the playout's numbers less the output buffer they include,
    /// which the latency counts under Output. For raw, the target is then just the safety margin.
    var bufferMs: Double { max((stats?.bufferedMs ?? 0) - offsetMs, 0) }
    var targetMs: Double { max((stats?.targetMs ?? 0) - offsetMs, 0) }
    var jitterMs: Double { stats?.jitterMs ?? 0 }
    private var offsetMs: Double { latency?.outputBufferMs ?? 0 }
    private(set) var history: [Sample] = []
    static let historyLength = 300

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastMissing = 0

    func start(_ model: AppModel) {
        self.model = model
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The window showing the meter: while it can't be seen (behind other windows, minimised, another Space) the
    /// numbers aren't read, so nothing redraws.
    @ObservationIgnored weak var window: NSWindow?

    private func poll() {
        if let window, !window.occlusionState.contains(.visible) { return }
        guard let reading = model?.streamReading() else {
            if stats != nil {
                stats = nil
                latency = nil
                history.removeAll()
            }
            return
        }
        let missing = reading.stats.underruns + reading.stats.lost
        // A new stream (counters went back to zero) isn't a dropout.
        let dropout = missing > lastMissing && stats != nil
        lastMissing = missing
        stats = reading.stats
        latency = reading.latency
        guard reading.stats.playing else { return }
        history.append(Sample(bufferMs: bufferMs, targetMs: targetMs, jitterMs: jitterMs, dropout: dropout))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}

/// SonoBus-style view of a stream: total latency and where it goes, the buffer against its target, and the
/// buffer's last 30 seconds with dropouts marked.
struct StreamMeter: View {
    let model: AppModel
    /// The one-line version for the menu panel.
    var compact = false
    @State private var feed = StreamMeterFeed()

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .background(WindowReader { feed.window = $0 })
        .onAppear { feed.start(model) }
        .onDisappear { feed.stop() }
    }

    // MARK: Menu panel

    private var compactBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(feed.stats?.playing == true ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(model.streamSource == AppModel.streamThisMac ? "This Mac" : AppModel.shown(model.streamSource))
                    Spacer()
                    Text(summary).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                // The bars only once audio flows; until then the line above says it's listening and hears nothing.
                if streaming {
                    BufferBar(feed: feed, scaleMs: scaleMs)
                        .frame(height: 6)
                    HStack(spacing: 10) {
                        levelPair(sourceName, .source)
                        levelPair("Here", .played)
                    }
                }
            }
        }
        .help(model.streamProblem ?? "Listening to \(AppModel.shown(model.streamSource))'s stream. Click for the Stream window.")
    }

    private var streaming: Bool {
        model.streamProblem == nil && !model.streamQuiet && feed.stats?.playing == true
    }

    private var sourceName: String {
        model.streamSource == AppModel.streamThisMac ? "Input" : AppModel.shown(model.streamSource)
    }

    private func levelPair(_ name: String, _ side: LiveLevels.Side) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            LiveLevels(model: model, side: side, readout: false)
        }
    }

    private var summary: String {
        if let problem = model.streamProblem { return problem }
        guard streaming else { return "Listening · no audio" }
        let latency = feed.latency.map { String(format: "≈ %.0f ms", $0.totalMs) } ?? String(format: "%.1f ms buffer", feed.bufferMs)
        // Only recent ones (the graph's 30 seconds): a count since the stream began only ever grows, and looks
        // alarming hours in even when all's well. Settings → Streaming has the total.
        let missing = feed.history.filter(\.dropout).count
        return missing > 0 ? "\(latency) · \(missing) dropout\(missing == 1 ? "" : "s") lately" : latency
    }

    // MARK: Settings

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let latency = feed.latency {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "≈ %.1f ms", latency.totalMs))
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                    Text("end to end").foregroundStyle(.secondary)
                    Spacer()
                }
                LatencyBar(latency: latency)
            } else if model.streamQuiet {
                Text("Nothing's playing on \(AppModel.shown(model.streamSource)), so the output is closed. It opens again when audio comes back.")
                    .foregroundStyle(.secondary)
            } else if feed.stats == nil || feed.stats?.playing == false {
                Text("Waiting for audio…").foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Levels").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("peak, -60 to 0 dB").font(.caption2).foregroundStyle(.secondary)
                }
                levelRow("At \(sourceName)", .source)
                levelRow("Here", .played)
            }

            if let stats = feed.stats, stats.playing {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Buffer").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f ms, aiming for %.1f", feed.bufferMs, feed.targetMs))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    BufferBar(feed: feed, scaleMs: scaleMs).frame(height: 8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last 30 seconds").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        legend
                    }
                    BufferHistory(samples: feed.history, scaleMs: scaleMs)
                        .frame(height: 70)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func levelRow(_ name: String, _ side: LiveLevels.Side) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.caption).frame(width: 80, alignment: .leading).lineLimit(1)
            LiveLevels(model: model, side: side, readout: true)
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            Label { Text("buffer") } icon: { Capsule().fill(Color.accentColor).frame(width: 10, height: 3) }
            Label { Text("target") } icon: { Capsule().fill(Color.secondary).frame(width: 10, height: 2) }
            if feed.stats?.method == .resilient {
                Label { Text("jitter") } icon: { RoundedRectangle(cornerRadius: 1).fill(Color.orange.opacity(0.3)).frame(width: 10, height: 6) }
            }
            Label { Text("dropout") } icon: { Rectangle().fill(Color.red).frame(width: 2, height: 8) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(TightLabelStyle())
    }

    /// One scale for the bar and the graph: a bit above the most the buffer (or its target) reached lately, in
    /// steps so it doesn't jitter.
    private var scaleMs: Double {
        let peak = max(feed.history.map { max($0.bufferMs, $0.targetMs) }.max() ?? 0, feed.bufferMs, feed.targetMs)
        return [2.0, 5, 10, 20, 40, 80, 160, 320].first { $0 >= peak * 1.15 } ?? 320
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

/// The buffer now: its fill, the target it's steering to, and (resilient) how much of that is for jitter.
struct BufferBar: View {
    let feed: StreamMeterFeed
    let scaleMs: Double

    // Drawn rather than laid out: it changes ten times a second, and sized views made SwiftUI lay out the whole
    // window each time.
    var body: some View {
        let stats = feed.stats
        let buffer = feed.bufferMs, target = feed.targetMs, jitter = feed.jitterMs
        Canvas { context, size in
            let w = size.width, h = size.height
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: h / 2)
            context.clip(to: track)
            context.fill(track, with: .style(.quaternary))
            guard let stats, stats.playing else { return }
            if stats.method == .resilient, jitter > 0 {
                let x = w * fraction(target - jitter)
                context.fill(Path(CGRect(x: x, y: 0, width: w * fraction(min(jitter, target)), height: h)),
                             with: .color(.orange.opacity(0.3)))
            }
            let filled = max(w * fraction(buffer), 3)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: filled, height: h), cornerRadius: h / 2),
                         with: .color(.accentColor))
            context.fill(Path(CGRect(x: w * fraction(target) - 1, y: 0, width: 2, height: h)), with: .color(.primary.opacity(0.6)))
        }
    }

    private func fraction(_ ms: Double) -> Double { min(max(ms / scaleMs, 0), 1) }
}

/// The buffer over the last 30 seconds, newest on the right.
struct BufferHistory: View {
    let samples: [StreamMeterFeed.Sample]
    let scaleMs: Double

    var body: some View {
        Canvas { context, size in
            let n = StreamMeterFeed.historyLength
            let dx = size.width / CGFloat(n - 1)
            let start = n - samples.count
            func x(_ i: Int) -> CGFloat { CGFloat(start + i) * dx }
            func y(_ ms: Double) -> CGFloat { size.height * (1 - CGFloat(min(max(ms / scaleMs, 0), 1))) }

            // Grid: a line per scale step quarter.
            for q in 1...3 {
                let gy = size.height * CGFloat(q) / 4
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: gy)); $0.addLine(to: CGPoint(x: size.width, y: gy)) },
                               with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }
            guard samples.count > 1 else { return }

            // Jitter band just under the target.
            var band = Path()
            for (i, s) in samples.enumerated() { let p = CGPoint(x: x(i), y: y(s.targetMs)); i == 0 ? band.move(to: p) : band.addLine(to: p) }
            for (i, s) in samples.enumerated().reversed() { band.addLine(to: CGPoint(x: x(i), y: y(s.targetMs - s.jitterMs))) }
            band.closeSubpath()
            context.fill(band, with: .color(.orange.opacity(0.2)))

            var target = Path()
            for (i, s) in samples.enumerated() { let p = CGPoint(x: x(i), y: y(s.targetMs)); i == 0 ? target.move(to: p) : target.addLine(to: p) }
            context.stroke(target, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

            var fill = Path()
            fill.move(to: CGPoint(x: x(0), y: size.height))
            for (i, s) in samples.enumerated() { fill.addLine(to: CGPoint(x: x(i), y: y(s.bufferMs))) }
            fill.addLine(to: CGPoint(x: x(samples.count - 1), y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(.accentColor.opacity(0.15)))
            var line = Path()
            for (i, s) in samples.enumerated() { let p = CGPoint(x: x(i), y: y(s.bufferMs)); i == 0 ? line.move(to: p) : line.addLine(to: p) }
            context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)

            for (i, s) in samples.enumerated() where s.dropout {
                context.fill(Path(CGRect(x: x(i) - 1, y: 0, width: 2, height: size.height)), with: .color(.red))
            }
        }
        .overlay(alignment: .topLeading) {
            Text("\(Int(scaleMs)) ms").font(.system(size: 9)).foregroundStyle(.secondary).padding(2)
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.4)))
    }
}

/// Where the latency goes, as one stacked bar with a legend.
struct LatencyBar: View {
    let latency: AudioStreamReceiver.Latency

    private var parts: [(name: String, ms: Double, color: Color)] {
        [("Capture", latency.captureMs, .purple),
         ("Network", latency.networkMs, .teal),
         ("Buffer", latency.bufferMs, .accentColor),
         ("Output", latency.outputMs, .green)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.name) { part in
                        Rectangle().fill(part.color)
                            .frame(width: max(geo.size.width * part.ms / max(latency.totalMs, 0.001) - 1, 0))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(parts, id: \.name) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.color).frame(width: 7, height: 7)
                        Text(part.name).foregroundStyle(.secondary)
                        Text(String(format: "%.1f", part.ms)).monospacedDigit()
                    }
                }
            }
            .font(.caption)
        }
        .help("Capture: the other Mac's input and packet. Network: half the round trip. Buffer: waiting to play. Output: this Mac's output buffer and device. Estimates from what the devices report.")
    }
}

/// Left and right peak level, -60…0 dBFS: green, yellow above -12, red above -3. Nil draws an empty meter.
struct StereoLevelMeter: View {
    let levels: AppModel.Stereo?

    private static let gradient = Gradient(stops: [
        .init(color: .green, location: 0), .init(color: .green, location: 0.79),
        .init(color: .yellow, location: 0.8), .init(color: .yellow, location: 0.94),
        .init(color: .red, location: 0.95), .init(color: .red, location: 1),
    ])

    // Drawn rather than laid out: it changes 20 times a second (see BufferBar).
    var body: some View {
        let left = levels?.left, right = levels?.right
        Canvas { context, size in
            let h = (size.height - 1) / 2
            for (i, db) in [left, right].enumerated() {
                let row = CGRect(x: 0, y: Double(i) * (h + 1), width: size.width, height: h)
                let shape = Path(roundedRect: row, cornerRadius: 1)
                context.fill(shape, with: .style(.quaternary))
                guard let db else { continue }
                let f = min(max((db + 60) / 60, 0), 1)
                var bar = context
                bar.clip(to: Path(CGRect(x: 0, y: row.minY, width: size.width * f, height: h)))
                bar.fill(shape, with: .linearGradient(Self.gradient, startPoint: CGPoint(x: 0, y: row.midY),
                                                      endPoint: CGPoint(x: size.width, y: row.midY)))
            }
        }
    }
}

/// One side's level meter (and its dB readout), reading the levels itself: they change 20 times a second, and read
/// in StreamMeter's body they rebuilt the whole meter (latency bar, history graph and all) every time.
private struct LiveLevels: View {
    enum Side { case source, played }
    let model: AppModel
    let side: Side
    let readout: Bool

    var body: some View {
        let levels = side == .source ? model.streamSourceLevels : model.streamPlayedLevels
        HStack(spacing: 8) {
            StereoLevelMeter(levels: levels).frame(height: readout ? 10 : 7)
            if readout {
                Text(levels.map { Self.db(max($0.left, $0.right)) } ?? "—")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            }
        }
    }

    private static func db(_ value: Double) -> String { value <= -60 ? "-∞" : "\(Int(value.rounded())) dB" }
}

/// Hands over the window a view is in, once it's in one.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in found(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window != nil { DispatchQueue.main.async { [weak view] in found(view?.window) } }
    }
}
