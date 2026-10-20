import Charts
import SwiftUI
import ThunerCore

/// The Stream window: the stream live (latency, levels, buffer, the last 30 seconds), this listening session's
/// totals and minute-by-minute graph, and earlier sessions. Opened from the panel's stream row, the ⋯ menu, or
/// Settings → Streaming.
struct StreamWindowView: View {
    @Bindable var model: AppModel
    /// An earlier session picked from the list, shown instead of the current one.
    @State private var picked: StreamSession.ID?
    @AppStorage("streamGraphRange") private var range = GraphRange.session
    @State private var meterHeight: CGFloat = 400

    /// How much the graph shows: the session on show, or a stretch of time up to now across every session.
    enum GraphRange: String, CaseIterable, Identifiable {
        case session, hour, sixHours, day, week
        var id: Self { self }
        var title: String {
            switch self {
            case .session: "Session"
            case .hour: "1 hour"
            case .sixHours: "6 hours"
            case .day: "24 hours"
            case .week: "7 days"
            }
        }
        var seconds: TimeInterval? {
            switch self {
            case .session: nil
            case .hour: 3600
            case .sixHours: 6 * 3600
            case .day: 86400
            case .week: 7 * 86400
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.streamSource.isEmpty {
                    notListening
                } else {
                    live
                }
                if let session = shownSession {
                    sessionBox(session)
                }
                if shownSession != nil || !model.streamLog.sessions.isEmpty {
                    graphBox
                }
                if !earlier.isEmpty {
                    earlierBox
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A click anywhere that isn't a control, or Esc, lets go of the keyboard focus.
            .contentShape(Rectangle())
            .onTapGesture { Self.clearFocus() }
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    static func clearFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: Live

    private var notListening: some View {
        GroupBox {
            HStack {
                Text("Not listening to a stream. Choose a Mac to listen to in Settings → Streaming.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Streaming Settings…") { AppWindows.shared.showSettings(.streaming) }
            }
            .padding(6)
        }
    }

    private var live: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let problem = model.streamProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                // In a hosting view of its own: its numbers change ten times a second, and each change made SwiftUI
                // lay out the whole window again (a fifth of a core). The window only hears about its height.
                IsolatedView(content: StreamMeter(model: model), height: $meterHeight)
                if let details = liveDetails {
                    Text(details).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(6)
        } label: {
            HStack {
                Text(model.streamSource == AppModel.streamThisMac ? "This Mac" : AppModel.shown(model.streamSource))
                    .font(.headline)
                Spacer()
                // Changing either restarts the stream (and starts a new session, for comparing them).
                ChoiceButtons(selection: $model.streamMethod,
                              choices: [(StreamMethod.raw, "Raw"), (StreamMethod.resilient, "Resilient")])
                .help("Raw: lowest latency, for Ethernet. Resilient: an adaptive buffer that rides out a busy network.")
                Picker(model.streamMethod == .raw ? "Margin" : "Minimum", selection: $model.streamMarginMs) {
                    ForEach([0.5, 1, 2, 3, 5, 10, 20], id: \.self) { ms in
                        Text(ms < 1 ? "0.5 ms" : "\(Int(ms)) ms").tag(ms)
                    }
                }
                .fixedSize()
                .controlSize(.small)
                .help(model.streamMethod == .raw ? "Safety margin on top of the output buffer" : "The least buffer it keeps")
            }
        }
    }

    /// What the stream is like right now, under the meter (the totals are in the session below).
    private var liveDetails: String? {
        guard let stats = model.streamStats else { return nil }
        var parts: [String] = []
        if let status = model.streamSenderStatus, status.sharing { parts.append("\(status.source ?? "?") on \(AppModel.shown(status.host))") }
        parts.append("\(Self.rate(stats.sampleRate)) 24-bit")
        if stats.method == .resilient { parts.append(String(format: "jitter %.1f ms", stats.jitterMs)) }
        parts.append(String(format: "clocks %+.0f ppm", stats.driftPPM))
        return parts.joined(separator: " · ")
    }

    // MARK: Sessions

    private var shownSession: StreamSession? {
        if let picked, let session = model.streamLog.sessions.first(where: { $0.id == picked }), session.id != model.streamSession?.id {
            return session
        }
        return model.streamSession
    }

    private var isCurrent: Bool { shownSession?.id == model.streamSession?.id && model.streamSession != nil }

    /// Earlier sessions, newest first (not the one in progress).
    private var earlier: [StreamSession] {
        model.streamLog.sessions.filter { $0.id != model.streamSession?.id }.reversed()
    }

    private func sessionBox(_ session: StreamSession) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                SessionTotals(session: session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            HStack {
                Text(isCurrent ? "This session" : "\(AppModel.shown(session.source)) · \(session.method.name)")
                    .font(.headline)
                Text(Self.span(session)).foregroundStyle(.secondary)
                Spacer()
                if isCurrent {
                    Button("New Session") { model.startNewStreamSession() }
                        .controlSize(.small)
                        .help("Saves this session's totals below and starts counting from zero")
                } else {
                    Button("Back to This Session") { picked = nil }
                        .controlSize(.small)
                        .disabled(model.streamSession == nil)
                }
            }
        }
    }

    // MARK: Graph

    /// Every session the graph can draw from: the saved ones and the one in progress (saved copies of which lag).
    private var allSessions: [StreamSession] {
        model.streamLog.sessions.filter { $0.id != model.streamSession?.id } + (model.streamSession.map { [$0] } ?? [])
    }

    private var graph: (points: [StreamPoint], from: Date, to: Date, step: TimeInterval)? {
        if let seconds = range.seconds {
            // To the end of this minute, so the graph's inputs (and so the graph) only change once a minute.
            let to = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 60)
            let from = to.addingTimeInterval(-seconds)
            let step = StreamTimeline.step(for: seconds)
            return (StreamTimeline.points(allSessions, from: from, to: to, step: step), from, to, step)
        }
        guard let session = shownSession else { return nil }
        let ended = session.started.addingTimeInterval((session.ended.timeIntervalSince(session.started) / 60).rounded(.up) * 60)
        let to = max(ended, session.started.addingTimeInterval(120))
        let step = StreamTimeline.step(for: to.timeIntervalSince(session.started))
        return (StreamTimeline.points([session], from: session.started, to: to.addingTimeInterval(1), step: step),
                session.started, to, step)
    }

    private var graphBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let graph, graph.points.count > 1 {
                    HStack {
                        Text(graph.step <= 60 ? "Each point is a minute" : "Each point averages \(StreamWindowView.duration(graph.step))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        SessionChart.legend
                    }
                    IsolatedChart(chart: SessionChart(points: graph.points, from: graph.from, to: graph.to, step: graph.step),
                                  height: 160)
                } else {
                    Text(range == .session
                         ? "The graph fills in once the session has played for a couple of minutes."
                         : "Nothing played in the last \(range.title).")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                }
            }
            .padding(6)
        } label: {
            HStack {
                Text("Graph").font(.headline)
                Spacer()
                ChoiceButtons(selection: $range, choices: GraphRange.allCases.map { ($0, $0.title) })
            }
        }
    }

    private var earlierBox: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(earlier) { session in
                    Button { picked = session.id } label: {
                        HStack {
                            Text(Self.span(session)).frame(minWidth: 170, alignment: .leading)
                            Text("\(AppModel.shown(session.source)) · \(session.method.name)")
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(Self.duration(session.playingSeconds)).monospacedDigit().foregroundStyle(.secondary)
                            Text(session.counters.dropouts == 1 ? "1 dropout" : "\(session.counters.dropouts) dropouts")
                                .monospacedDigit()
                                .foregroundStyle(session.counters.dropouts > 0 ? .orange : .secondary)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(picked == session.id ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.callout)
            .padding(4)
        } label: {
            HStack {
                Text("Earlier sessions").font(.headline)
                Spacer()
                Button("Clear") {
                    picked = nil
                    model.clearStreamLog()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Formatting

    static func span(_ session: StreamSession) -> String {
        let day = session.started.formatted(.dateTime.month(.abbreviated).day())
        let from = session.started.formatted(date: .omitted, time: .shortened)
        let to = session.ended.formatted(date: .omitted, time: .shortened)
        return "\(day), \(from)–\(to)"
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "\(Int(seconds)) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func rate(_ hz: Double) -> String {
        hz.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(hz / 1000)) kHz" : String(format: "%.1f kHz", hz / 1000)
    }
}

/// A session's totals and averages, in a grid.
private struct SessionTotals: View {
    let session: StreamSession

    var body: some View {
        let c = session.counters
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                item("Playing", StreamWindowView.duration(session.playingSeconds))
                item("Dropouts", "\(c.dropouts)", warn: c.dropouts > 0)
                item("Lost", "\(c.lost)", warn: c.lost > 0)
                item("Late", "\(c.late)")
            }
            GridRow {
                item("Latency", pair(session.averageLatencyMs, session.latencyMaxMs))
                item("Buffer", pair(session.averageBufferMs, session.playingSeconds > 0 ? session.bufferMaxMs : nil))
                if session.method == .resilient {
                    item("Jitter (worst)", String(format: "%.1f ms", session.jitterMaxMs))
                    item("Resends", c.resendsRequested == 0 ? "None" : "\(c.resendsRecovered) of \(c.resendsRequested) back")
                } else {
                    item("Clock corrections", "\(c.corrections)")
                    item("Packets", c.received.formatted())
                }
            }
        }
    }

    private func item(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(warn ? .orange : .primary)
        }
    }

    /// "8.2 ms, worst 11.0"
    private func pair(_ average: Double?, _ worst: Double?) -> String {
        guard let average else { return "—" }
        guard let worst else { return String(format: "%.1f ms", average) }
        return String(format: "%.1f ms, worst %.1f", average, worst)
    }
}

/// A view in a hosting view of its own, so its frequent changes stay inside it. It tells the window its height
/// when that changes (rarely), and otherwise the window never lays it out.
private struct IsolatedView<Content: View>: NSViewRepresentable {
    let content: Content
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: root)
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = root
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: height)
    }

    private var root: AnyView {
        let binding = $height
        return AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                    if abs(new - binding.wrappedValue) > 0.5 { binding.wrappedValue = new }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
    }
}

/// The chart in a hosting view of its own. The window's live numbers change size ten times a second, and each
/// time SwiftUI measured everything in the window again, Charts included (a fifth of a core while the window was
/// open). Here the window sees a plain view of a fixed height, and the chart lays itself out only when its data
/// or width changes.
private struct IsolatedChart: NSViewRepresentable {
    let chart: SessionChart
    let height: CGFloat

    func makeNSView(context: Context) -> NSHostingView<SessionChart> {
        let view = NSHostingView(rootView: chart)
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<SessionChart>, context: Context) {
        if view.rootView != chart { view.rootView = chart }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<SessionChart>, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: height)
    }
}

/// The buffer over time (average, with its worst as a band), its target, and dropouts in red. Lines break where
/// nothing played.
private struct SessionChart: View, Equatable {
    let points: [StreamPoint]
    let from: Date
    let to: Date
    let step: TimeInterval

    static var legend: some View {
        HStack(spacing: 10) {
            Label { Text("buffer") } icon: { Capsule().fill(Color.accentColor).frame(width: 10, height: 3) }
            Label { Text("worst") } icon: { RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.25)).frame(width: 10, height: 6) }
            Label { Text("target") } icon: { Capsule().fill(Color.secondary).frame(width: 10, height: 2) }
            Label { Text("dropouts") } icon: { Rectangle().fill(Color.red).frame(width: 2, height: 9) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var span: TimeInterval { to.timeIntervalSince(from) }

    var body: some View {
        Chart {
            ForEach(points, id: \.time) { point in
                if point.playingSeconds > 0 {
                    AreaMark(x: .value("Time", point.time), yStart: .value("Buffer", point.bufferMs),
                             yEnd: .value("Worst", point.bufferMaxMs), series: .value("Series", "worst \(point.run)"))
                        .foregroundStyle(Color.accentColor.opacity(0.18))
                    LineMark(x: .value("Time", point.time), y: .value("Buffer", point.bufferMs),
                             series: .value("Series", "buffer \(point.run)"))
                        .foregroundStyle(Color.accentColor)
                    LineMark(x: .value("Time", point.time), y: .value("Target", point.targetMs),
                             series: .value("Series", "target \(point.run)"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if point.dropouts > 0 {
                    RuleMark(x: .value("Time", point.time))
                        .foregroundStyle(Color.red.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .annotation(position: .top, spacing: 0) {
                            Text("\(point.dropouts)").font(.system(size: 9)).foregroundStyle(.red)
                        }
                }
            }
        }
        .chartXScale(domain: from...to)
        .chartYAxisLabel("ms")
        .chartXAxis {
            if span > 2 * 86400 {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day())
                }
            } else {
                AxisMarks(values: .stride(by: .minute, count: labelMinutes)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
        }
    }

    /// About six time labels, on round minutes.
    private var labelMinutes: Int {
        let minutes = span / 60
        return [1, 2, 5, 10, 15, 30, 60, 120, 180, 240].first { minutes / Double($0) <= 6 } ?? 360
    }
}

/// A row of choices with the chosen one filled in the accent colour. (macOS's segmented control shows the chosen
/// segment as a light raised button, which reads as the opposite.)
private struct ChoiceButtons<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.0) { value, title in
                let chosen = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(.callout.weight(chosen ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .foregroundStyle(chosen ? Color.white : Color.primary)
                        .background(chosen ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}
