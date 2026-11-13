import Foundation

/// Injectable time so the engine can be tested deterministically.
public protocol TimeSource {
    /// Wall clock; may jump when the user or NTP adjusts it.
    var now: Date { get }
    /// Monotonic seconds the machine has been awake; does not advance during sleep.
    var uptime: TimeInterval { get }
    /// Current UTC offset in seconds.
    var tzOffset: Int { get }
}

public struct SystemTime: TimeSource {
    public init() {}
    public var now: Date { Date() }
    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public var tzOffset: Int { TimeZone.autoupdatingCurrent.secondsFromGMT() }
}

/// The single writer of the activity timeline.
///
/// Every input (app switch, idle tick, lock, sleep, user command, rule change) only flips a
/// flag; `reconcile` then compares what *should* be recorded right now with the one interval
/// that is currently open and closes/opens rows accordingly. Because there is never more than
/// one open interval and each new one starts at or after the previous end, sessions cannot
/// overlap or be double-counted, and duplicate events are no-ops.
///
/// Durations come from the monotonic uptime clock, so wall-clock adjustments and sleep never
/// add or remove tracked time. Not thread-safe: drive it from the main thread.
public final class TrackingEngine {
    public struct FrontApp: Equatable, Sendable {
        public var bundleID: String
        public var name: String
        public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
    }

    public enum Status: Equatable, Sendable {
        case stopped, paused, idle, waiting
        /// The Personal profile is on: activity is recorded, but none of it as work.
        case personal
        case tracking(SessionKind)
    }

    struct Descriptor: Equatable {
        var kind: SessionKind
        var bundleID: String?
        var appName: String?
        var categoryID: Int64?
        var projectID: Int64?
        var source: TrackingSource
        var tzOffset: Int
        /// A work application used in the Personal profile: recorded as non-work, but it is the
        /// evidence behind the "Is this work?" suggestion and can be moved to work on request.
        var personalWork = false
    }

    struct Open {
        var id: Int64
        var startWall: Date
        var startUptime: TimeInterval
        var desc: Descriptor
    }

    /// Intervals shorter than this are dropped (rapid Cmd-Tab noise). The time is lost, never invented.
    public static let minimumDuration: TimeInterval = 1
    /// How often the open interval's end is written to disk; bounds what a crash can lose.
    public static let checkpointInterval: TimeInterval = 30
    /// Wall clock vs. monotonic disagreement that counts as a clock change or an unnoticed sleep.
    static let driftTolerance: TimeInterval = 2

    private let store: Store
    private let time: TimeSource
    public private(set) var settings: AppSettings
    public private(set) var frontApp: FrontApp?
    /// An explicit Start…Stop work session is running (manual and hybrid modes).
    public private(set) var manualActive = false
    public private(set) var paused = false
    public private(set) var idle = false
    public private(set) var locked = false
    public private(set) var asleep = false
    /// AI agent(s) currently working, as reported by their hooks ("Claude Code", "Codex"); nil = none.
    public private(set) var agent: String?
    /// Start of the current uninterrupted stretch of activity (reset by idle, pause, stop, sleep).
    public private(set) var sessionStart: Date?
    private var open: Open?
    private var lastEnd = Date.distantPast
    private var lastEndUptime = -TimeInterval.infinity
    private var lastCheckpoint: TimeInterval = 0
    private var runFloor: TimeInterval
    private var rules: [String: AppRule] = [:]
    private var categories: [Int64: WorkCategory] = [:]

    /// Work-application intervals recorded in Personal since the user was last away.
    private var evidenceIDs: [Int64] = []
    private var evidenceClosed: TimeInterval = 0
    /// The work application most recently used in the Personal profile.
    public private(set) var evidenceApp: String?

    /// Called after anything observable changed.
    public var onChange: (() -> Void)?
    public var onError: ((Error) -> Void)?
    /// Work hours ended while the user still works: the Work profile stays on (overtime).
    public var onWorkHoursEnded: (() -> Void)?

    public init(store: Store, time: TimeSource = SystemTime()) {
        self.store = store
        self.time = time
        runFloor = time.uptime
        settings = Self.loadSettings(store)
        loadState()
    }

    /// Tracking modes and Stop no longer exist in the app: Personal is the state that counts no
    /// work. Settings saved by an older version are moved to that model once.
    private static func loadSettings(_ store: Store) -> AppSettings {
        var settings = (try? store.loadSettings()) ?? AppSettings()
        if settings.mode != .automatic || !settings.autoEnabled {
            if !settings.autoEnabled { settings.profile = .personal }
            settings.mode = .automatic
            settings.autoEnabled = true
            try? store.saveSettings(settings)
        }
        return settings
    }

    private func loadState() {
        lastEnd = (try? store.latestEnd()) ?? .distantPast
        rules = Dictionary(((try? store.rules()) ?? []).map { ($0.bundleID, $0) }, uniquingKeysWith: { $1 })
        categories = Dictionary(((try? store.categories()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    /// Call once at launch, before any event: finalises rows a crash left open.
    public func recover() {
        attempt { try store.recoverUnclosed() }
        lastEnd = (try? store.latestEnd()) ?? .distantPast
    }

    // MARK: - State

    private var wantsRecording: Bool {
        settings.mode == .manual ? manualActive : (settings.autoEnabled || manualActive)
    }

    public var isRecording: Bool { wantsRecording && !paused && !asleep }

    public var status: Status {
        if !wantsRecording { return .stopped }
        if settings.profile == .personal { return .personal }
        if paused { return .paused }
        // The user being away does not make it "idle" while an agent is recording work.
        if asleep || ((idle || locked) && !agentWorking) { return .idle }
        guard let open else { return .waiting }
        return .tracking(open.desc.kind)
    }

    public var canStart: Bool { settings.mode == .automatic ? !settings.autoEnabled : !manualActive }
    public var canStop: Bool { wantsRecording }
    public var canPause: Bool { wantsRecording && !paused }
    public var canResume: Bool { wantsRecording && paused }

    /// The wall clock is behind the newest recorded session, so new time is appended after it.
    public var clockBehind: Bool { lastEnd.timeIntervalSince(time.now) > 60 }

    public var idleThreshold: TimeInterval {
        if let app = frontApp, let override = rules[app.bundleID]?.idleThreshold { return TimeInterval(override) }
        return TimeInterval(settings.idleThreshold)
    }

    public func category(for app: FrontApp) -> WorkCategory? {
        categories[rules[app.bundleID]?.categoryID ?? Store.uncategorizedID]
    }

    /// The open interval is agent work (not the user's own activity).
    public var agentWorking: Bool { open?.desc.source == .agent }

    // MARK: - Work hours

    private var localNow: Double { time.now.timeIntervalSince1970 + Double(time.tzOffset) }

    public var inWorkHours: Bool { settings.schedule.contains(local: localNow) }

    /// The Work profile is on outside work hours.
    public var isOvertime: Bool { settings.schedule.isUsable && settings.profile == .work && !inWorkHours }

    /// When the current work hours end (nil outside work hours).
    public var workHoursEnd: Date? {
        settings.schedule.currentEnd(local: localNow).map { Date(timeIntervalSince1970: $0 - Double(time.tzOffset)) }
    }

    /// The most recent end of work hours (the moment overtime began).
    public var lastWorkHoursEnd: Date? {
        settings.schedule.lastEnd(atOrBefore: localNow).map { Date(timeIntervalSince1970: $0 - Double(time.tzOffset)) }
    }

    public var nextWorkHoursStart: Date? {
        settings.schedule.nextStart(after: localNow).map { Date(timeIntervalSince1970: $0 - Double(time.tzOffset)) }
    }

    /// Time in work applications while Personal is on, since the user was last away.
    public var evidenceSeconds: TimeInterval {
        var total = evidenceClosed
        if let o = open, o.desc.personalWork { total += max(0, time.uptime - o.startUptime) }
        return total
    }

    public func clearEvidence() {
        evidenceIDs = []
        evidenceClosed = 0
        evidenceApp = nil
    }

    /// Acts on each start and end of work hours once, and ends overtime when the user stops.
    /// A choice the user makes between the two boundaries is left alone.
    private func applySchedule(idleSeconds: TimeInterval) -> Bool {
        let schedule = settings.schedule
        guard schedule.isUsable else { return false }
        let now = localNow
        let before = settings.profile
        var marks = settings
        if let start = schedule.lastStart(atOrBefore: now), start > settings.lastStartApplied {
            marks.lastStartApplied = start
            if schedule.contains(local: now) { setProfile(.work, reason: "hours") }
        }
        let agentBusy = agent != nil && settings.countAgentWork
        let away = idle || locked || asleep
        if let end = schedule.lastEnd(atOrBefore: now), end > settings.lastEndApplied {
            marks.lastEndApplied = end
            if settings.profile == .work, !schedule.contains(local: now) {
                // Still at work a moment after the end: that is overtime. Otherwise the day is over.
                if now - end < 300, !paused, !away || agentBusy { onWorkHoursEnded?() } else { setProfile(.personal, reason: "hours") }
            }
        }
        if settings.profile == .work, !schedule.contains(local: now), !agentBusy,
           locked || asleep || idleSeconds >= Double(settings.returnIdleMinutes) * 60 {
            setProfile(.personal, reason: "hours")
        }
        if marks.lastStartApplied != settings.lastStartApplied || marks.lastEndApplied != settings.lastEndApplied {
            settings.lastStartApplied = marks.lastStartApplied
            settings.lastEndApplied = marks.lastEndApplied
            attempt { try store.saveSettings(settings) }
        }
        return settings.profile != before
    }

    /// What should be on the timeline right now; nil = record nothing.
    private func desired() -> Descriptor? {
        guard isRecording else { return nil }
        let own = ownActivity()
        // An agent working on the user's behalf counts as work whenever the user's own activity
        // does not already: while idle, locked, or in a non-work or ignored application.
        // The user's own work keeps its own application, so nothing is counted twice.
        if let agent, settings.countAgentWork, settings.profile == .work, own?.kind != .work {
            return Descriptor(kind: .work, bundleID: "agent." + agent, appName: agent, categoryID: Store.workID,
                              projectID: settings.activeProjectID, source: .agent, tzOffset: time.tzOffset)
        }
        return own
    }

    /// What the user's own activity amounts to right now.
    private func ownActivity() -> Descriptor? {
        let tz = time.tzOffset
        let source: TrackingSource = manualActive ? .manual : .automatic
        if idle || locked { return Descriptor(kind: .idle, source: source, tzOffset: tz) }
        // No known foreground app means no evidence of activity: record nothing.
        guard let app = frontApp else { return nil }
        let rule = rules[app.bundleID]
        let category = categories[rule?.categoryID ?? Store.uncategorizedID]
        if let category, category.kind == .excluded {
            // Ignored apps leave a time-only trace: the app's identity is never stored.
            return Descriptor(kind: .excluded, categoryID: category.id, source: source, tzOffset: tz)
        }
        var kind = category?.kind ?? .nonwork
        var categoryID = category?.id ?? Store.uncategorizedID
        let unclassified = categoryID == Store.uncategorizedID
        let countsAsWork = manualActive || (unclassified && settings.unclassifiedIsWork && !Browsers.isBrowser(app.bundleID))
        if countsAsWork && kind != .work {
            kind = .work
            categoryID = Store.workID
        }
        if kind == .work, settings.profile == .personal {
            // Personal counts no work. The application and its category stay on the row, so this
            // time can be moved to work if the user says that it was work.
            return Descriptor(kind: .nonwork, bundleID: app.bundleID, appName: app.name, categoryID: categoryID,
                              projectID: nil, source: source, tzOffset: tz, personalWork: true)
        }
        let project = kind == .work ? (rule?.projectID ?? settings.activeProjectID) : nil
        return Descriptor(kind: kind, bundleID: app.bundleID, appName: app.name, categoryID: categoryID,
                          projectID: project, source: source, tzOffset: tz)
    }

    // MARK: - Timeline

    @discardableResult
    private func reconcile(_ reason: String, at uptime: TimeInterval? = nil) -> Bool {
        let want = desired()
        guard want != open?.desc else { return false }
        let u = uptime ?? time.uptime
        // A new run of recording can never reach back before the moment it began.
        if open == nil { runFloor = time.uptime }
        closeOpen(reason, at: u)
        if let want { openNew(want, at: u) }
        if want == nil || want?.kind == .idle {
            sessionStart = nil
            clearEvidence()
        } else if sessionStart == nil {
            sessionStart = open?.startWall
        }
        return true
    }

    private func closeOpen(_ reason: String, at u: TimeInterval) {
        guard let o = open else { return }
        open = nil
        let duration = max(0, u - o.startUptime)
        attempt {
            if duration < Self.minimumDuration {
                try store.deleteSessions([o.id])
            } else {
                let end = o.startWall.addingTimeInterval(duration)
                try store.updateEnd(o.id, end: end, reason: reason)
                lastEnd = max(lastEnd, end)
                lastEndUptime = max(u, o.startUptime)
                if o.desc.personalWork {
                    evidenceIDs.append(o.id)
                    evidenceClosed += duration
                }
            }
        }
    }

    private func openNew(_ d: Descriptor, at u: TimeInterval) {
        // Never start before the previous interval ended, in monotonic terms (an idle trim can
        // reach back past it) or in wall-clock terms (the clock may have been set backwards).
        let startUptime = max(u, lastEndUptime, runFloor)
        let wall = time.now.addingTimeInterval(startUptime - time.uptime)
        let start = max(wall, lastEnd)
        let session = Session(start: start, end: start, tzOffset: d.tzOffset, kind: d.kind, bundleID: d.bundleID,
                              appName: d.appName, categoryID: d.categoryID, projectID: d.projectID, source: d.source)
        attempt {
            let id = try store.insert(session)
            open = Open(id: id, startWall: start, startUptime: startUptime, desc: d)
            lastCheckpoint = time.uptime
            if d.personalWork { evidenceApp = d.appName }
        }
    }

    /// Persists the open interval's current end so a crash loses at most `checkpointInterval`.
    public func checkpoint() {
        guard let o = open else { return }
        let u = time.uptime
        lastCheckpoint = u
        attempt { try store.updateEnd(o.id, end: o.startWall.addingTimeInterval(max(0, u - o.startUptime)), reason: "") }
    }

    /// If wall clock and monotonic clock disagree (clock adjusted, or a sleep we were not told
    /// about), close the interval with its true monotonic duration and start a fresh one at "now".
    private func resyncIfDrifted() {
        guard let o = open else { return }
        let u = time.uptime
        let expected = o.startWall.addingTimeInterval(u - o.startUptime)
        guard abs(time.now.timeIntervalSince(expected)) > Self.driftTolerance else { return }
        log.notice("clock drift detected; re-anchoring open interval")
        closeOpen("clock", at: u)
        openNew(o.desc, at: u)
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch {
            log.error("storage error: \(String(describing: error), privacy: .public)")
            onError?(error)
        }
    }

    private func notify(_ changed: Bool = true) {
        if changed { onChange?() }
    }

    // MARK: - System events

    public func appActivated(_ app: FrontApp) {
        guard app != frontApp else { return }
        frontApp = app
        reconcile("switch")
        notify()
    }

    /// Heartbeat. `idleSeconds` is the time since the last keyboard/mouse input.
    public func tick(idleSeconds: TimeInterval) {
        let u = time.uptime
        let threshold = idleThreshold
        var changed: Bool
        if !idle, threshold > 0, idleSeconds >= threshold {
            // Trim back to the last input: the quiet stretch before the threshold was not activity.
            idle = true
            changed = reconcile("idle", at: u - idleSeconds)
        } else if idle, threshold <= 0 || idleSeconds < threshold {
            idle = false
            changed = reconcile("activity", at: u - max(0, idleSeconds))
        } else {
            changed = reconcile("switch")  // picks up time-zone changes
        }
        changed = applySchedule(idleSeconds: idleSeconds) || changed
        resyncIfDrifted()
        if u - lastCheckpoint >= Self.checkpointInterval * 0.8 { checkpoint() }
        notify(changed)
    }

    public func screenLocked() {
        guard !locked else { return }
        locked = true
        let changed = reconcile("lock")
        notify(applySchedule(idleSeconds: 0) || changed)
    }

    public func screenUnlocked() {
        guard locked else { return }
        locked = false
        notify(reconcile("activity"))
    }

    public func willSleep() {
        guard !asleep else { return }
        asleep = true
        let changed = reconcile("sleep")
        notify(applySchedule(idleSeconds: 0) || changed)
    }

    public func didWake() {
        guard asleep else { return }
        asleep = false
        notify(reconcile("activity"))
    }

    /// Reports which AI agent is working (nil = none), from the hook signals. `endedAgo` back-dates
    /// the end when the agent went quiet without saying so: its last sign of life was that long ago.
    public func setAgent(_ name: String?, endedAgo: TimeInterval = 0) {
        guard name != agent else { return }
        agent = name
        notify(reconcile(name == nil ? "done" : "agent", at: time.uptime - max(0, endedAgo)))
    }

    public func clockChanged() {
        resyncIfDrifted()
        notify()
    }

    /// Seconds until the next `tick` is needed: frequent only near the idle threshold or while idle.
    public func nextCheckDelay(idleSeconds: TimeInterval) -> TimeInterval {
        guard isRecording, !locked else { return Self.checkpointInterval }
        if idle { return 3 }
        let threshold = idleThreshold
        guard threshold > 0 else { return Self.checkpointInterval }
        return min(Self.checkpointInterval, max(1, threshold - idleSeconds))
    }

    // MARK: - User commands

    public func start() {
        paused = false
        switch settings.mode {
        case .automatic: setAutoEnabled(true)
        case .manual: manualActive = true
        case .hybrid: if settings.autoEnabled { manualActive = true } else { setAutoEnabled(true) }
        }
        reconcile("start")
        notify()
    }

    public func stop() {
        paused = false
        switch settings.mode {
        case .automatic: setAutoEnabled(false)
        case .manual: manualActive = false
        case .hybrid: if manualActive { manualActive = false } else { setAutoEnabled(false) }
        }
        reconcile("stop")
        notify()
    }

    public func pause() {
        guard canPause else { return }
        paused = true
        reconcile("pause")
        notify()
    }

    public func resume() {
        guard paused else { return }
        paused = false
        reconcile("resume")
        notify()
    }

    /// Turns the Work profile on. With `includeEvidence`, the time just spent in work
    /// applications while Personal was on is moved to work first: there is evidence for it.
    public func startWork(includeEvidence: Bool = false) {
        guard settings.profile != .work else { return }
        if includeEvidence {
            closeOpen("profile", at: time.uptime)
            let ids = evidenceIDs
            attempt { try store.markAsWork(ids) }
        }
        setProfile(.work, reason: "profile")
        notify()
    }

    /// Turns the Personal profile on: from now on nothing counts as work.
    public func endWork() {
        guard settings.profile != .personal else { return }
        setProfile(.personal, reason: "profile")
        notify()
    }

    private func setProfile(_ profile: Profile, reason: String) {
        guard settings.profile != profile else { return }
        paused = false
        settings.profile = profile
        attempt { try store.saveSettings(settings) }
        clearEvidence()
        reconcile(reason)
    }

    private func setAutoEnabled(_ on: Bool) {
        guard settings.autoEnabled != on else { return }
        settings.autoEnabled = on
        attempt { try store.saveSettings(settings) }
    }

    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        if next.mode != settings.mode {
            manualActive = false
            paused = false
            if next.mode != .manual { next.autoEnabled = true }
        }
        settings = next
        attempt { try store.saveSettings(next) }
        // Applies from now on: the open interval is closed and a new one opened under the new rules.
        reconcile("rules")
        notify()
    }

    /// Reloads application rules and categories after they were edited.
    public func reloadRules() {
        loadState()
        reconcile("rules")
        notify()
    }

    /// Runs a manual correction with the open interval closed, so edits can never fight the tracker.
    @discardableResult
    public func performEdit<T>(_ body: () throws -> T) rethrows -> T {
        closeOpen("edit", at: time.uptime)
        defer {
            lastEnd = (try? store.latestEnd()) ?? .distantPast
            reconcile("edit")
            notify()
        }
        return try body()
    }

    /// Re-reads everything after the database was replaced or wiped.
    public func reload() {
        closeOpen("rules", at: time.uptime)
        attempt { try store.recoverUnclosed() }  // e.g. a restored backup taken mid-session
        sessionStart = nil
        manualActive = false
        paused = false
        clearEvidence()
        settings = Self.loadSettings(store)
        loadState()
        reconcile("rules")
        notify()
    }

    /// Closes the open interval; call on quit.
    public func shutdown() {
        closeOpen("quit", at: time.uptime)
        sessionStart = nil
    }
}
