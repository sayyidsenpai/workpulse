import AppKit
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WorkPulseCore

private let applog = Logger(subsystem: "com.workpulse.app", category: "app")

enum MainTab: String, CaseIterable, Identifiable {
    case history = "History", reports = "Reports", work = "Work", rules = "Apps", sleep = "Sleep", settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .history: "list.bullet"
        case .reports: "chart.bar"
        case .work: "briefcase"
        case .rules: "square.grid.2x2"
        case .sleep: "moon"
        case .settings: "slider.horizontal.3"
        }
    }
}

/// Totals shown on the dashboard, as of `asOf`. Views add the seconds since then for a live count.
struct Summary {
    var asOf = Date()
    var today = DayTotals()
    var day: PeriodResult?
    var week: PeriodResult?
    var month: PeriodResult?
    /// Today's work time outside the work hours (Fixed hours).
    var overtime: TimeInterval = 0
    /// When this week's work reached the weekly goal (Flexible); nil before that.
    var weekGoalAt: Date?
    /// Today's work time that an AI agent did.
    var agent: TimeInterval = 0
    /// Work recorded in the current work session (see `AppSettings.workSessionStart`).
    var sessionWork: TimeInterval = 0
    /// This week's work days and any other day with work (`extra`: not planned), in order.
    var weekDays: [(day: LocalDay, worked: Bool, off: Bool, extra: Bool)] = []

    /// Seconds of work since `asOf`, while work is being recorded. Every live number adds this,
    /// so the popover, the hero and the menu bar always count the same way.
    func live(at now: Date, working: Bool) -> TimeInterval { working ? max(0, now.timeIntervalSince(asOf)) : 0 }
}

/// An AI coding agent WorkPulse can detect, and whether its hook has ever reported.
struct AgentInfo: Identifiable, Equatable {
    let tool: String
    let name: String
    var lastSignal: Date?
    /// The WorkPulse hook entries are in the agent's configuration file.
    var hookInstalled: Bool
    var id: String { tool }
    var connected: Bool { lastSignal != nil }
}

/// "You used Xcode for 12 minutes. Is this work?": shown in Personal, only with evidence.
struct Suggestion: Equatable {
    var app: String
    var minutes: Int
}

/// Glue between the core (store + engine) and the views. All derived numbers come from the
/// store through `Aggregator`, so every screen shows the same totals.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    @ObservationIgnored let store: Store
    @ObservationIgnored let engine: TrackingEngine
    @ObservationIgnored let reminders = SleepReminders()
    @ObservationIgnored private var monitor: ActivityMonitor?
    @ObservationIgnored private var mainWindow: NSWindow?
    @ObservationIgnored private var onboardingWindow: NSWindow?
    /// Decides when the goal sound plays (see `GoalCue`).
    @ObservationIgnored private var goalCue = GoalCue()
    /// The state last written to the log, so each change is logged once.
    @ObservationIgnored private var loggedHeadline: Headline?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var rescheduling: Task<Void, Never>?

    var settings: AppSettings
    var summary = Summary()
    var status = TrackingEngine.Status.stopped
    var frontApp: TrackingEngine.FrontApp?
    var workSessionStart: Date?
    var idleSince: Date?
    /// Bumped whenever stored data may have changed; history and reports reload on it.
    var revision = 0
    var banner: String?
    var categories: [WorkCategory] = []
    var rules: [AppRule] = []
    var goals: [GoalConfig] = []
    var pay: [Compensation] = []
    var tab = MainTab.history
    var launchAtLogin = false
    var loginItemNote: String?
    var notificationStatus = "…"
    var isOvertime = false
    var isDayOff = false
    /// Set while today's day off can still be undone.
    var dayOffUndo: DayOffUndo?
    /// The popover shows the day-off confirmation instead of the status card.
    var confirmingDayOff = false
    /// True from "End work" in work hours until the popover closes: the Personal card asks once.
    var offerDayOff = false
    var agentWorking = false
    /// The title and folder chips of the status card while agents work.
    var agentDisplay = AgentDisplay([])
    var suggestion: Suggestion?
    var agents: [AgentInfo] = []
    var workHoursEnd: Date?
    var lastWorkHoursEnd: Date?
    var nextWorkHoursStart: Date?

    /// Minutes in work applications, in Personal, before WorkPulse asks "Is this work?".
    static let suggestionMinutes = 12

    private init() {
        let override = ProcessInfo.processInfo.environment["WORKPULSE_DATA_DIR"]
        let directory = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkPulse", isDirectory: true)
        var note: String?
        var opened: Store
        do {
            opened = try Store(directory: directory)
            note = opened.recoveryNote
        } catch {
            // Disk storage failed (permissions, full disk…). Keep working in memory and say so.
            applog.error("storage unavailable: \(String(describing: error), privacy: .public)")
            opened = try! Store()
            note = "Storage is unavailable (\(error.localizedDescription)). WorkPulse is running in memory and activity will not be saved."
        }
        store = opened
        banner = note
        engine = TrackingEngine(store: opened)
        settings = engine.settings
    }

    func start() {
        engine.recover()
        engine.onChange = { [weak self] in self?.refresh() }
        engine.onError = { [weak self] error in self?.banner = "Storage error: \(error.localizedDescription)" }
        engine.onWorkHoursEnded = { [weak self] in self?.workHoursEnded() }
        engine.onWorkHoursStarted = { [weak self] in self?.workHoursStarted() }
        reminders.onEndWork = { [weak self] in self?.endWork() }
        reminders.onDayOff = { [weak self] in self?.takeDayOff(moveWork: true) }
        reloadReference()
        let monitor = ActivityMonitor(engine: engine)
        monitor.onTick = { [weak self] in self?.tick() }
        monitor.agentsDirectory = store.directory?.appendingPathComponent("agents")
        installAgentHook()
        self.monitor = monitor
        #if DEBUG
        if Self.demo {
            // Pictures for the documentation: a fixed front application instead of the real one.
            // WORKPULSE_DEMO_APP="<bundle id>:<name>" picks another application in front.
            let app = (ProcessInfo.processInfo.environment["WORKPULSE_DEMO_APP"] ?? "com.apple.dt.Xcode:Xcode").split(separator: ":")
            engine.appActivated(.init(bundleID: String(app[0]), name: String(app.last ?? app[0])))
            engine.tick(idleSeconds: 0)
        } else {
            monitor.start()
        }
        #else
        monitor.start()
        #endif
        refresh()
        reminders.configure()
        // The work-hours notices need permission too. macOS asks only once; later calls return at once.
        let notices = settings.schedule.isUsable && (settings.notifyWorkStart || settings.notifyWorkEnd)
        rescheduleReminders(requestPermission: notices)
        refreshLoginItem()
        dailyBackup()
        if !settings.onboarded && !CommandLine.arguments.contains("--snapshot") { showOnboarding() }
        applog.notice("WorkPulse started; data at \(self.store.directory?.path ?? "memory", privacy: .public)")
    }

    /// Keeps a copy of the agent hook script at a stable path (the data folder) that Claude Code
    /// and Codex hook configurations can point to, wherever the app itself is installed.
    private func installAgentHook() {
        guard let directory = store.directory, let source = Bundle.main.url(forResource: "agent-hook", withExtension: "sh") else { return }
        let target = directory.appendingPathComponent("agent-hook.sh")
        guard !FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) else { return }
        attempt {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
    }

    func shutdown() {
        engine.shutdown()
        store.close()
    }

    private func tick() {
        dailyBackup()
        // Slightly under the poll period so a 30 s poll always refreshes (and checkpoints).
        guard Date().timeIntervalSince(lastRefresh) >= TrackingEngine.checkpointInterval * 0.8 else { return }
        refresh()
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch {
            applog.error("\(String(describing: error), privacy: .public)")
            banner = error.localizedDescription
        }
    }

    // MARK: - Derived state

    func refresh() {
        engine.checkpoint()
        lastRefresh = Date()
        settings = engine.settings
        status = engine.status
        frontApp = engine.frontApp
        workSessionStart = engine.workSessionStart
        idleSince = engine.idleSince
        let today = LocalDay.today()
        let week = Period.week.range(containing: today, firstWeekday: settings.firstWeekday)
        let month = Period.month.range(containing: today, firstWeekday: settings.firstWeekday)
        var sessions: [Session] = []
        attempt { sessions = try store.sessions(days: min(week.lowerBound, month.lowerBound)...max(week.upperBound, month.upperBound)) }
        let totals = Aggregator.dayTotals(sessions)
        summary = Summary(asOf: Date(), today: totals[today] ?? DayTotals(),
                          day: evaluate(.day, totals), week: evaluate(.week, totals), month: evaluate(.month, totals),
                          overtime: Aggregator.overtime(sessions, on: today, schedule: settings.schedule),
                          agent: Aggregator.dayTotals(sessions) { $0.source == .agent && $0.kind == .work }[today]?.work ?? 0,
                          sessionWork: workSessionStart.map { start in
                              // A session can be older than the loaded week and month: read it from its start.
                              let own = start < sessions.first?.start ?? .distantFuture ? ((try? store.sessions(from: start)) ?? sessions) : sessions
                              return Aggregator.work(own, since: start)
                          } ?? 0)
        summary.weekGoalAt = summary.week?.targetSeconds.flatMap { $0 > 0 ? Aggregator.reached($0, in: week, sessions: sessions) : nil }
        let scheduled = Goals.config(on: today, projectID: nil, in: goals)?.workingDays ?? settings.schedule.days
        summary.weekDays = week.days.compactMap { day in
            let worked = Goals.isWorkingDay(totals[day]?.work ?? 0, on: day, configs: goals)
            let off = settings.schedule.isDayOff(day.index)
            // A worked day that was not planned (a weekend, a day off) is marked, and counted like in Reports.
            let planned = scheduled.contains(day.weekday) && !off
            return scheduled.contains(day.weekday) || worked
                ? (day: day, worked: worked, off: off && !worked, extra: worked && !planned) : nil
        }
        isDayOff = engine.isDayOffToday
        dayOffUndo = settings.dayOffUndo.flatMap { $0.day == today.index ? $0 : nil }
        if isDayOff || status != .personal { confirmingDayOff = false }
        // Flexible: overtime is work over the weekly goal. Fixed hours: work outside the work hours.
        isOvertime = Goals.inOvertime(week: summary.week, profile: settings.profile, outsideHours: engine.isOvertime)
        agentWorking = engine.agentWorking
        let display = AgentDisplay(engine.agentSessions)
        if display != agentDisplay { agentDisplay = display }
        workHoursEnd = engine.workHoursEnd
        lastWorkHoursEnd = engine.lastWorkHoursEnd
        nextWorkHoursStart = engine.nextWorkHoursStart
        let evidence = Int(engine.evidenceSeconds / 60)
        suggestion = status == .personal && !isDayOff && evidence >= Self.suggestionMinutes && settings.suggestionMutedDay != today.index
            ? Suggestion(app: engine.evidenceApp ?? "a work application", minutes: evidence) : nil
        refreshAgents()
        applyTheme()
        // The goal that the popover leads with: the weekly goal in Flexible, the daily goal in Fixed hours.
        let reached = flexible ? summary.weekGoalAt != nil
            : summary.day?.targetSeconds.map { $0 > 0 && summary.today.work >= $0 } ?? false
        if goalCue.update(reached: reached, flexible: flexible, target: flexible ? summary.week?.targetSeconds : summary.day?.targetSeconds) {
            Sounds.play(.goal, mode: settings.sounds)
        }
        if headline != loggedHeadline {
            applog.info("state \(String(describing: self.headline), privacy: .public), goal reached \(reached, privacy: .public)")
            loggedHeadline = headline
        }
        revision += 1
    }

    var goalReached: Bool { goalCue.isReached }

    /// This week counts overtime by the Flexible rule (the rule of the goal version in force).
    var flexible: Bool { summary.week?.overtimeRule == .flexible }

    /// How overtime counts from today. Without a stored goal: Flexible before onboarding (the
    /// default for new users), Fixed hours after it (the rule every report used before the choice).
    var overtimeRule: OvertimeRule {
        Goals.config(on: .today(), projectID: nil, in: goals)?.overtime ?? (settings.onboarded ? .fixed : .flexible)
    }

    /// Light, dark, or the appearance of macOS, for every WorkPulse window and the popover.
    private func applyTheme() {
        let wanted: NSAppearance? = switch settings.theme {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance?.name != wanted?.name { NSApp.appearance = wanted }
    }

    /// Per-day totals for a range of local days, optionally for one profile only.
    func totals(days: ClosedRange<LocalDay>, projectID: Int64? = nil) -> [LocalDay: DayTotals] {
        var sessions: [Session] = []
        attempt { sessions = try store.sessions(days: days) }
        return Aggregator.dayTotals(sessions) { projectID == nil || $0.projectID == projectID }
    }

    func evaluate(_ period: Period, _ totals: [LocalDay: DayTotals], projectID: Int64? = nil) -> PeriodResult {
        Goals.evaluate(period, containing: .today(), totals: totals, configs: goals, projectID: projectID,
                       today: .today(), firstWeekday: settings.firstWeekday, isDayOff: isDayOff(_:))
    }

    /// For goals and reports: a day in the list of days off.
    func isDayOff(_ day: LocalDay) -> Bool { settings.schedule.isDayOff(day.index) }

    var isWorking: Bool { status == .tracking(.work) }

    /// The small text at the top right of the status card: always about work hours.
    var workHoursNote: String {
        guard settings.schedule.isUsable else { return "" }
        if let end = workHoursEnd { return "Until \(Fmt.time(end))" }
        if let end = lastWorkHoursEnd, Calendar.current.isDateInToday(end) { return "Work hours ended at \(Fmt.time(end))" }
        if let start = nextWorkHoursStart, Calendar.current.isDateInToday(start) { return "Work hours start at \(Fmt.time(start))" }
        return "No work hours today"
    }

    /// The one decision of what the current state is called (see `Headline`).
    var headline: Headline { Headline(status: status, overtime: isOvertime, agent: agentWorking, dayOff: isDayOff) }

    /// Menu bar icon: one shape per state, so the state never depends on colour.
    var statusSymbol: String {
        switch headline {
        case .overtime: flexible ? "target" : "clock"
        case .agent: "terminal"
        case .tracking: goalReached ? "checkmark.circle" : "stopwatch.fill"
        case .nonwork, .ignored, .waiting: "stopwatch"
        case .idle: "moon"
        case .personal: "person.crop.circle"
        case .dayOff: "calendar.badge.minus"
        }
    }

    var statusText: String {
        switch headline {
        case .overtime: flexible ? "Over your weekly goal" : "Overtime"
        case .agent: agentDisplay.title
        case .tracking: "Tracking work"
        case .nonwork: "Active · non-work"
        case .ignored: "Ignored application"
        case .idle: "Idle"
        case .waiting: "Waiting for activity"
        case .personal: "Personal"
        case .dayOff: "Day off"
        }
    }

    /// Menu bar text; refreshed with the summary (at least every 30 s), shown to the minute.
    var menuBarText: String? {
        if settings.menuBarDisplay == .iconOnly { return nil }
        // Off work: the name only. A work number here reads as personal time and pulls you back to work.
        let prefix: String
        switch headline {
        case .personal, .dayOff: return statusText
        case .idle: prefix = "Idle · "
        case .overtime: prefix = "Overtime · "
        default: prefix = ""
        }
        let seconds = settings.menuBarDisplay == .session ? summary.sessionWork : summary.today.work
        return prefix + Fmt.duration(seconds, seconds: false)
    }

    /// What VoiceOver reads for the menu bar item.
    var menuBarLabel: String {
        "WorkPulse. \(statusText). Today \(Fmt.duration(summary.today.work, seconds: false))." + (suggestion == nil ? "" : " One suggestion.")
    }

    // MARK: - Work and Personal

    /// "Start overtime" outside work hours with Fixed hours, "Start work" otherwise. In Flexible,
    /// work outside work hours is not overtime.
    var startLabel: String { !flexible && settings.schedule.isUsable && !engine.inWorkHours ? "Start overtime" : "Start work" }

    func startWork(includeEvidence: Bool = false) {
        engine.startWork(includeEvidence: includeEvidence)
        Sounds.play(.up, mode: settings.sounds)
    }

    func endWork() {
        guard settings.profile == .work else { return }
        engine.endWork()
        reminders.clearWorkHoursEnded()
        Sounds.play(.down, mode: settings.sounds)
        // Work ended early: ask one time, in this popover only, if today is a day off.
        offerDayOff = engine.inWorkHours && !isDayOff
    }

    /// The answer "Not work": no more suggestions today.
    // MARK: - Days off

    /// From the Personal card in work hours: ask first when today already has work time.
    func requestDayOff() {
        if todayWork.apps.isEmpty { takeDayOff(moveWork: false) } else { confirmingDayOff = true }
    }

    func takeDayOff(moveWork: Bool) {
        confirmingDayOff = false
        offerDayOff = false
        engine.takeDayOff(moveWork: moveWork)
        applog.notice("day off: moved \(self.settings.dayOffUndo?.moved.count ?? 0) sessions to Personal")
        reminders.clearWorkHoursStarted()
    }

    func undoDayOff() { engine.undoDayOff() }

    /// Today's work time by application, largest first (for the day-off confirmation).
    var todayWork: (apps: [(name: String, bundleID: String?, seconds: TimeInterval)], from: Date?, to: Date?) {
        let day = LocalDay.today()
        var sessions: [Session] = []
        attempt { sessions = try store.sessions(days: day...day) }
        var sums: [String: (bundleID: String?, seconds: TimeInterval)] = [:]
        let now = Date()
        var from: Date?
        var to: Date?
        for s in sessions where s.kind == .work && LocalDay(date: s.start, tzOffset: s.tzOffset) == day {
            from = min(from ?? s.start, s.start)
            to = max(to ?? s.end, s.endReason.isEmpty ? now : s.end)
            // The open session is stored with its start as end; count it to now.
            let seconds = s.endReason.isEmpty ? max(s.duration, now.timeIntervalSince(s.start)) : s.duration
            let name = s.appName ?? "Created by hand"
            sums[name, default: (s.bundleID, 0)].seconds += seconds
        }
        let apps = sums.map { (name: $0.key, bundleID: $0.value.bundleID, seconds: $0.value.seconds) }
            .filter { $0.seconds >= 1 }.sorted { $0.seconds > $1.seconds }
        return (apps, from, to)
    }

    /// Adds days off from the Work screen. Returns false when the range overlaps a day off in the list.
    @discardableResult
    func addDaysOff(from: LocalDay, to: LocalDay, name: String) -> Bool {
        let entry = DayOff(from: from.index, to: to.index, name: name.trimmingCharacters(in: .whitespaces))
        guard !settings.schedule.daysOff.contains(where: { $0.overlaps(entry) }) else { return false }
        updateSettings {
            $0.schedule.daysOff.append(entry)
            $0.schedule.daysOff.sort { $0.from < $1.from }
        }
        return true
    }

    func removeDayOff(_ entry: DayOff) {
        updateSettings { settings in
            settings.schedule.daysOff.removeAll { $0 == entry }
            if settings.dayOffUndo.map({ entry.contains($0.day) }) == true { settings.dayOffUndo = nil }
        }
    }

    func notWork() {
        engine.clearEvidence()
        updateSettings { $0.suggestionMutedDay = LocalDay.today().index }
    }

    /// Work hours started and WorkPulse changed to Work: say it once, quietly, without a question.
    private func workHoursStarted() {
        applog.notice("work hours started; changed to Work; start notice \(self.settings.notifyWorkStart ? "on" : "off", privacy: .public)")
        guard settings.notifyWorkStart else { return }
        let start = engine.lastWorkHoursStart.map(Fmt.time) ?? ""
        Task { await reminders.workHoursStarted(at: start) }
    }

    /// Work hours ended while the user still works: say it once, then leave the user alone.
    private func workHoursEnded() {
        Sounds.play(.hoursEnded, mode: settings.sounds)
        guard settings.notifyWorkEnd else { return }
        let end = engine.lastWorkHoursEnd.map(Fmt.time) ?? ""
        Task { await reminders.workHoursEnded(at: end) }
    }

    /// The daily goal in force today, in minutes.
    var dailyGoalMinutes: Int? {
        Goals.config(on: .today(), projectID: nil, in: goals)?.dailyHours.map { Int(($0 * 60).rounded()) }
    }

    /// Saves the work hours, the daily goal and how overtime counts. The goal and the rule apply
    /// from today; the weekly and monthly goals follow from the goal and the work days. Work hours
    /// are always on: both rules use them.
    func saveWork(schedule: WorkSchedule, goalMinutes: Int, overtime: OvertimeRule) {
        var schedule = schedule
        schedule.enabled = true
        let turnedOn = schedule.isUsable && !settings.schedule.isUsable
        schedule.daysOff = settings.schedule.daysOff   // days off are edited on their own
        if schedule != settings.schedule { updateSettings { $0.schedule = schedule } }
        var goal = Goals.config(on: .today(), projectID: nil, in: goals) ?? GoalConfig(effectiveFrom: .today())
        let before = goal
        goal.dailyHours = Double(goalMinutes) / 60
        goal.weeklyHours = nil
        goal.monthlyHours = nil
        goal.weeklyDays = nil
        goal.minDayMinutes = 30
        goal.workingDays = schedule.days
        goal.overtime = overtime
        // The hours go with the goal version, so Fixed hours judges each earlier day by its own hours.
        goal.startMinutes = schedule.startMinutes
        goal.endMinutes = schedule.endMinutes
        if goal != before {
            goal.id = 0
            goal.effectiveFrom = .today()
            edit { try store.saveGoal(goal) }
        }
        if turnedOn { rescheduleReminders(requestPermission: true) }   // the end-of-hours notice needs permission
    }

    // MARK: - AI agents

    private var agentsDirectory: URL? { store.directory?.appendingPathComponent("agents") }

    /// The home folder that holds the agents' configuration (overridable for tests and snapshots).
    private var home: URL {
        ProcessInfo.processInfo.environment["WORKPULSE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var agentConnected: Bool { agents.contains { $0.connected } }

    private func refreshAgents() {
        let found = AgentSignals.tools.map { tool in
            AgentInfo(tool: tool, name: AgentSignals.name(tool),
                      lastSignal: agentsDirectory.flatMap { AgentSignals.lastSignal(tool, in: $0) },
                      hookInstalled: AgentSetup.isInstalled(tool, home: home))
        }
        if found != agents { agents = found }
    }

    func agentConfigPath(_ tool: String) -> String {
        (AgentSetup.configURL(tool, home: home).path as NSString).abbreviatingWithTildeInPath
    }

    func agentBackupPath(_ tool: String) -> String? {
        let url = AgentSetup.backupURL(tool, home: home)
        return FileManager.default.fileExists(atPath: url.path) ? (url.path as NSString).abbreviatingWithTildeInPath : nil
    }

    /// Adds the WorkPulse hook to the agent's configuration. Returns false (with a banner) on failure.
    @discardableResult
    func installAgentHooks(_ tool: String) -> Bool {
        var done = false
        attempt { try AgentSetup.install(tool, home: home); done = true }
        refreshAgents()
        return done
    }

    func undoAgentHooks(_ tool: String) {
        attempt { try AgentSetup.undo(tool, home: home) }
        refreshAgents()
    }

    func categoryName(_ s: Session) -> String {
        if s.kind == .idle { return "Idle" }
        return categories.first { $0.id == s.categoryID }?.name ?? Fmt.kind(s.kind)
    }

    // MARK: - Settings and reference data

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        engine.updateSettings(change)  // persists, re-evaluates tracking, then calls refresh()
    }

    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.updateSettings { $0[keyPath: keyPath] = value } })
    }

    func reloadReference() {
        attempt {
            categories = try store.categories()
            rules = try store.rules()
            goals = try store.goalConfigs()
            pay = try store.compensation()
        }
    }

    /// Runs a change to rules, categories, projects, goals or pay, then refreshes everything.
    func edit(_ body: () throws -> Void) {
        attempt(body)
        reloadReference()
        engine.reloadRules()  // applies to tracking from now on; ends with refresh()
    }

    func rule(for bundleID: String) -> AppRule? { rules.first { $0.bundleID == bundleID } }

    func setRule(_ rule: AppRule) {
        edit {
            // A rule that says nothing is no rule.
            if rule.categoryID == Store.uncategorizedID && rule.idleThreshold == nil && rule.projectID == nil {
                try store.deleteRule(rule.bundleID)
            } else {
                try store.saveRule(rule)
            }
        }
    }

    // MARK: - Sessions

    @discardableResult
    func saveSession(_ session: Session) -> Bool {
        do {
            try engine.performEdit { try store.saveManual(session) }
            return true
        } catch {
            banner = error.localizedDescription
            return false
        }
    }

    func deleteSessions(_ ids: Set<Int64>) {
        attempt { try engine.performEdit { try store.deleteSessions(Array(ids)) } }
    }

    // MARK: - Windows, export

    func showMain(_ tab: MainTab) {
        self.tab = tab
        if mainWindow == nil {
            let window = glassWindow(MainView().environment(self), size: NSSize(width: 1080, height: 720), resizable: true)
            window.setFrameAutosaveName("WorkPulseMain2")
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// A window whose content runs under a transparent title bar, so the glass reaches the top edge.
    private func glassWindow(_ view: some View, size: NSSize, resizable: Bool) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "WorkPulse"
        window.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                                     : [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Not movable by its background: a drag on the dial, the slider or a list would move the
        // window instead of the control. The window moves by its top edge, as a normal window does.
        window.isMovableByWindowBackground = false
        window.setContentSize(size)
        // With a full-size content view the view also covers the title bar, but the content size
        // excludes it: the window became 32 pt taller than a fixed-size view, an empty band below it.
        if !resizable { window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false) }
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            onboardingWindow = glassWindow(OnboardingView().environment(self), size: OnboardingView.size, resizable: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    /// Stores the answers from onboarding. Nothing is tracked differently until this point.
    func finishOnboarding(schedule: WorkSchedule, goalMinutes: Int, overtime: OvertimeRule,
                          workApps: [(bundleID: String, name: String)], launchAtLogin: Bool) {
        for app in workApps {
            var rule = self.rule(for: app.bundleID) ?? AppRule(bundleID: app.bundleID, appName: app.name)
            rule.categoryID = Store.workID
            setRule(rule)
        }
        saveWork(schedule: schedule, goalMinutes: goalMinutes, overtime: overtime)
        if launchAtLogin != self.launchAtLogin { setLaunchAtLogin(launchAtLogin) }
        updateSettings { $0.onboarded = true }
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    func export(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try text.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: - Launch at login

    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginItemNote = status == .requiresApproval ? "Waiting for approval in System Settings › General › Login Items." : nil
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            banner = "Could not change the login item: \(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    // MARK: - Sleep reminders

    func setSleep(_ sleep: SleepSettings) {
        let turnedOn = sleep.enabled && !settings.sleep.enabled
        updateSettings { $0.sleep = sleep }
        rescheduleReminders(requestPermission: turnedOn)
    }

    /// Serialised so quick successive changes always end with the latest schedule.
    func rescheduleReminders(requestPermission: Bool) {
        let previous = rescheduling
        rescheduling = Task {
            await previous?.value
            if requestPermission { await reminders.requestAuthorization() }
            await reminders.reschedule(settings.sleep)
            notificationStatus = await reminders.status()
        }
    }

    // MARK: - Backup, restore, deletion

    /// One automatic backup per day, taken the first time the app is active that day.
    private func dailyBackup() {
        let today = LocalDay.today().index
        guard store.directory != nil, settings.lastBackupDay != today else { return }
        attempt { try store.backup() }
        updateSettings { $0.lastBackupDay = today }
    }

    func backupNow() -> String? {
        var name: String?
        attempt { name = try store.backup().lastPathComponent }
        return name
    }

    func restore(from backup: URL) {
        engine.shutdown()
        attempt { try store.restore(from: backup) }
        engine.reload()
        reloadReference()
        refresh()
        rescheduleReminders(requestPermission: false)
    }

    func deleteHistory() {
        attempt { try engine.performEdit { try store.deleteAllSessions() } }
    }

    func deleteEverything() {
        attempt { try engine.performEdit { try store.deleteEverything() } }
        engine.reload()
        reloadReference()
        refresh()
        rescheduleReminders(requestPermission: false)
    }
}

// MARK: - Formatting and small shared views

@MainActor
enum Fmt {
    static func duration(_ seconds: TimeInterval, seconds showSeconds: Bool = true) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        if m > 0 || !showSeconds { return "\(m)m" }
        return "\(total)s"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func hours(_ seconds: TimeInterval) -> String { String(format: "%.1f h", seconds / 3600) }

    static func source(_ source: TrackingSource) -> String {
        switch source {
        case .automatic: "Automatic"
        case .manual: "Manual session"
        case .entry: "Created by hand"
        case .agent: "AI agent"
        }
    }

    static func kind(_ kind: SessionKind) -> String {
        switch kind {
        case .work: "Work"
        case .nonwork: "Non-work"
        case .idle: "Idle"
        case .excluded: "Excluded"
        }
    }

    private static var formatters: [String: DateFormatter] = [:]

    /// Formats in the UTC offset the session was recorded in, matching how it is bucketed into days.
    static func date(_ date: Date, offset: Int, _ template: String) -> String {
        let key = "\(offset)|\(template)"
        if let cached = formatters[key] { return cached.string(from: date) }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[key] = formatter
        return formatter.string(from: date)
    }

    static func day(_ day: LocalDay, _ template: String = "EEEdMMMyyyy") -> String {
        date(day.utcDate, offset: 0, template)
    }
}

/// Re-renders its content once a second while visible (live counters).
struct Live<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in content(context.date) }
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
