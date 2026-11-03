import Foundation
import os
import ThunerCore

/// ThUNER's logger. Every line goes to the system log (subsystem `com.idallas.thuner`, the category as before,
/// so `log stream` over SSH still works) and to the activity log the Activity window shows. `activity(_:)` is
/// what the panel's Activity says; the rest is the "Everything" level.
struct ThunerLogger: Sendable {
    let category: String
    private let system: Logger

    init(_ category: String) {
        self.category = category
        system = Logger(subsystem: "com.idallas.thuner", category: category)
    }

    /// A line in plain words, for the panel and the Activity level.
    func activity(_ message: String) {
        system.notice("\(message, privacy: .public)")
        ActivityStore.shared.add(.activity, category: category, message: message)
    }

    func notice(_ message: String) {
        system.notice("\(message, privacy: .public)")
        ActivityStore.shared.add(.detail, category: category, message: message)
    }

    func info(_ message: String) {
        system.info("\(message, privacy: .public)")
        ActivityStore.shared.add(.detail, category: category, message: message)
    }

    func debug(_ message: String) {
        system.debug("\(message, privacy: .public)")
        ActivityStore.shared.add(.detail, category: category, message: message)
    }

    func warning(_ message: String) {
        system.warning("\(message, privacy: .public)")
        ActivityStore.shared.add(.detail, category: category, message: message, isError: true)
    }

    func error(_ message: String) {
        system.error("\(message, privacy: .public)")
        ActivityStore.shared.add(.detail, category: category, message: message, isError: true)
    }

    func fault(_ message: String) {
        system.fault("\(message, privacy: .public)")
        ActivityStore.shared.add(.detail, category: category, message: message, isError: true)
    }
}

/// The activity log itself: in memory for the window and the API, appended line by line to
/// `~/Library/Application Support/Thuner/activity.jsonl`, trimmed at launch and every hour (see
/// `ActivityLog.trimmed`). Safe to call from any thread; the UI follows it through `ActivityFeed`.
final class ActivityStore: @unchecked Sendable {
    static let shared = ActivityStore()

    /// Called (off the main thread) with each new entry, for the API's event streams.
    var onEntry: (@Sendable (ActivityLog.Entry) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onEntry }
        set { lock.lock(); _onEntry = newValue; lock.unlock() }
    }

    private let lock = NSLock()
    private var _onEntry: (@Sendable (ActivityLog.Entry) -> Void)?
    private var entries: [ActivityLog.Entry] = []
    private var nextID = 1
    private var pendingForUI: [ActivityLog.Entry] = []
    private var flushScheduled = false
    private var loaded = false
    private let queue = DispatchQueue(label: "com.idallas.thuner.activity", qos: .utility)
    private var handle: FileHandle?
    private var trimTimer: DispatchSourceTimer?

    static let url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Thuner", isDirectory: true)
        .appendingPathComponent("activity.jsonl")

    /// Reads the file (once, at launch), puts what's in it before anything logged so far, trims, and starts the
    /// hourly trim. Lines logged before this were already appended to the file, in order.
    func load() {
        queue.sync {
            let text = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
            let old = ActivityLog.entries(in: text)
            lock.lock()
            guard !loaded else { lock.unlock(); return }
            loaded = true
            var all = old + entries
            for i in all.indices { all[i].id = i + 1 }
            entries = all
            nextID = all.count + 1
            pendingForUI.removeAll()
            lock.unlock()
            trimLocked(rewrite: true)
            DispatchQueue.main.async { ActivityFeed.shared.entries = self.snapshot() }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3600, repeating: 3600)
        timer.setEventHandler { [weak self] in self?.trimLocked(rewrite: false) }
        timer.resume()
        trimTimer = timer
    }

    func add(_ level: ActivityLog.Level, category: String, message: String, isError: Bool = false) {
        lock.lock()
        let entry = ActivityLog.Entry(id: nextID, date: Date(), level: level, category: category, message: message, isError: isError)
        nextID += 1
        entries.append(entry)
        pendingForUI.append(entry)
        let schedule = !flushScheduled
        flushScheduled = true
        let onEntry = _onEntry
        lock.unlock()
        queue.async { [self] in append(entry) }
        if schedule {
            // Many lines can arrive in a burst (launch, a stream starting); the window hears about them together.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in flushToFeed() }
        }
        onEntry?(entry)
    }

    /// Everything kept, oldest first.
    func snapshot() -> [ActivityLog.Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// For the API: entries after `id` (or the most recent `limit`), at the Activity level or everything.
    func entries(after id: Int?, level: ActivityLog.Level, limit: Int) -> [ActivityLog.Entry] {
        lock.lock(); defer { lock.unlock() }
        let filter = ActivityLog.Filter(level: level)
        let picked = entries.lazy.filter { entry in (id.map { entry.id > $0 } ?? true) && filter.matches(entry) }
        return id != nil ? Array(picked.prefix(limit)) : Array(picked.suffix(limit))
    }

    @MainActor
    private func flushToFeed() {
        lock.lock()
        let pending = pendingForUI
        pendingForUI.removeAll()
        flushScheduled = false
        lock.unlock()
        ActivityFeed.shared.entries.append(contentsOf: pending)
    }

    // MARK: The file (on `queue`)

    private func append(_ entry: ActivityLog.Entry) {
        if handle == nil { open() }
        handle?.write(Data((ActivityLog.line(for: entry) + "\n").utf8))
    }

    private func open() {
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Drops what's too old or over the budget. The file is rewritten when something was dropped (or asked for).
    private func trimLocked(rewrite: Bool) {
        lock.lock()
        let before = entries.count
        let kept = ActivityLog.trimmed(entries)
        let dropped = kept.count != before
        if dropped { entries = kept; pendingForUI.removeAll() }
        lock.unlock()
        guard dropped || rewrite else { return }
        let text = kept.map(ActivityLog.line(for:)).joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        try? handle?.close()
        handle = nil
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: Self.url, options: .atomic)
        if dropped { DispatchQueue.main.async { ActivityFeed.shared.entries = kept } }
    }
}

/// What the Activity window and the panel follow: the log so far, oldest first, updated a few times a second at
/// most.
@MainActor @Observable
final class ActivityFeed {
    static let shared = ActivityFeed()
    var entries: [ActivityLog.Entry] = []
}
