import AppKit
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WorkPulseCore

private let applog = Logger(subsystem: "com.workpulse.app", category: "app")

enum MainTab: String, CaseIterable, Identifiable {
    case history = "History", reports = "Reports", goals = "Goals", rules = "Apps", sleep = "Sleep", settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .history: "list.bullet.rectangle"
        case .reports: "chart.bar"
        case .goals: "target"
        case .rules: "square.grid.2x2"
        case .sleep: "moon"
        case .settings: "gearshape"
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
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var rescheduling: Task<Void, Never>?

    var settings: AppSettings
    var summary = Summary()
    var status = TrackingEngine.Status.stopped
    var frontApp: TrackingEngine.FrontApp?
    var sessionStart: Date?
    /// Bumped whenever stored data may have changed; history and reports reload on it.
    var revision = 0
    var banner: String?
    var categories: [WorkCategory] = []
    var projects: [Project] = []
    var rules: [AppRule] = []
    var goals: [GoalConfig] = []
    var pay: [Compensation] = []
    var tab = MainTab.history
    var launchAtLogin = false
    var loginItemNote: String?
    var notificationStatus = "…"

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
        reloadReference()
        let monitor = ActivityMonitor(engine: engine)
        monitor.onTick = { [weak self] in self?.tick() }
        monitor.agentsDirectory = store.directory?.appendingPathComponent("agents")
        installAgentHook()
        self.monitor = monitor
        monitor.start()
        refresh()
        reminders.configure()
        rescheduleReminders(requestPermission: false)
        refreshLoginItem()
        dailyBackup()
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
        sessionStart = engine.sessionStart
        let today = LocalDay.today()
        let week = Period.week.range(containing: today, firstWeekday: settings.firstWeekday)
        let month = Period.month.range(containing: today, firstWeekday: settings.firstWeekday)
        let totals = self.totals(days: min(week.lowerBound, month.lowerBound)...max(week.upperBound, month.upperBound))
        summary = Summary(asOf: Date(), today: totals[today] ?? DayTotals(),
                          day: evaluate(.day, totals), week: evaluate(.week, totals), month: evaluate(.month, totals))
        revision += 1
    }

    /// Per-day totals for a range of local days, optionally for one profile only.
    func totals(days: ClosedRange<LocalDay>, projectID: Int64? = nil) -> [LocalDay: DayTotals] {
        var sessions: [Session] = []
        attempt { sessions = try store.sessions(days: days) }
        return Aggregator.dayTotals(sessions) { projectID == nil || $0.projectID == projectID }
    }

    func evaluate(_ period: Period, _ totals: [LocalDay: DayTotals], projectID: Int64? = nil) -> PeriodResult {
        Goals.evaluate(period, containing: .today(), totals: totals, configs: goals, projectID: projectID,
                       today: .today(), firstWeekday: settings.firstWeekday)
    }

    var isWorking: Bool { status == .tracking(.work) }

    var statusSymbol: String {
        switch status {
        case .tracking(.work): "stopwatch.fill"
        case .tracking, .waiting: "stopwatch"
        case .idle: "zzz"
        case .paused: "pause.circle"
        case .stopped: "stop.circle"
        }
    }

    var statusText: String {
        switch status {
        case .tracking(.work):
            if engine.agentWorking { "\(engine.agent ?? "Agent") working" }
            else if engine.manualActive { "Manual work session" }
            else { "Tracking work" }
        case .tracking(.nonwork): "Active · non-work"
        case .tracking(.excluded): "Excluded app"
        case .tracking(.idle), .idle: "Idle · auto-paused"
        case .waiting: "Waiting for activity"
        case .paused: "Paused"
        case .stopped: settings.mode == .manual ? "No session running" : "Tracking stopped"
        }
    }

    var statusColor: Color {
        switch status {
        case .tracking(.work): .green
        case .tracking(.nonwork), .tracking(.excluded), .waiting: .blue
        case .tracking(.idle), .idle, .paused: .orange
        case .stopped: .secondary
        }
    }

    /// Menu bar text; refreshed with the summary (at least every 30 s), shown to the minute.
    var menuBarText: String? {
        switch settings.menuBarDisplay {
        case .iconOnly: nil
        case .today: Fmt.duration(summary.today.work, seconds: false)
        case .session: sessionStart.map { Fmt.duration(summary.asOf.timeIntervalSince($0), seconds: false) }
        }
    }

    func categoryName(_ s: Session) -> String {
        if s.kind == .idle { return "Idle" }
        return categories.first { $0.id == s.categoryID }?.name ?? Fmt.kind(s.kind)
    }

    func projectName(_ id: Int64?) -> String {
        projects.first { $0.id == id }?.name ?? "No project"
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
            projects = try store.projects()
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

    func deleteProject(_ id: Int64) {
        if settings.activeProjectID == id { updateSettings { $0.activeProjectID = nil } }
        edit { try store.deleteProject(id) }
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: MainView().environment(self)))
            window.title = "WorkPulse"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 680))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("WorkPulseMain")
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
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

struct WeekdayPicker: View {
    @Binding var days: Set<Int>
    let firstWeekday: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach((0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }, id: \.self) { day in
                Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(
                    get: { days.contains(day) },
                    set: { on in if on { days.insert(day) } else { days.remove(day) } }))
                    .toggleStyle(.button)
            }
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }.padding([.horizontal, .top], 12)
            }
            TabView(selection: $model.tab) {
                HistoryView().tabItem { Label("History", systemImage: MainTab.history.symbol) }.tag(MainTab.history)
                ReportsView().tabItem { Label("Reports", systemImage: MainTab.reports.symbol) }.tag(MainTab.reports)
                GoalsView().tabItem { Label("Goals", systemImage: MainTab.goals.symbol) }.tag(MainTab.goals)
                RulesView().tabItem { Label("Apps & Rules", systemImage: MainTab.rules.symbol) }.tag(MainTab.rules)
                SleepView().tabItem { Label("Sleep", systemImage: MainTab.sleep.symbol) }.tag(MainTab.sleep)
                SettingsView().tabItem { Label("Settings", systemImage: MainTab.settings.symbol) }.tag(MainTab.settings)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 580)
    }
}
