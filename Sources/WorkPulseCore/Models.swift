import Foundation

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case work, nonwork, idle, excluded
}

/// How a session came to exist.
public enum TrackingSource: String, Codable, Sendable {
    case automatic  // classified by application rules
    case manual     // recorded during an explicit Start…Stop work session
    case entry      // created by hand in History
    case agent      // recorded while an AI coding agent was working on the user's behalf
}

public enum TrackingMode: String, Codable, CaseIterable, Sendable {
    case automatic, manual, hybrid
}

public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable {
    case iconOnly, today, session
}

/// A calendar day in the wall-clock time of wherever the activity was recorded.
/// `index` counts days since 1970-01-01 in that local time, so day arithmetic is plain integer
/// math and never depends on the time zone the Mac happens to be in when a report is viewed.
public struct LocalDay: Hashable, Comparable, Codable, Sendable {
    public var index: Int

    public init(index: Int) { self.index = index }

    public init(date: Date, tzOffset: Int) {
        index = Int(((date.timeIntervalSince1970 + Double(tzOffset)) / 86400).rounded(.down))
    }

    public init(year: Int, month: Int, day: Int) {
        let date = Self.utc.date(from: DateComponents(year: year, month: month, day: day))!
        index = Int((date.timeIntervalSince1970 / 86400).rounded(.down))
    }

    public static func today(_ now: Date = Date(), zone: TimeZone = .autoupdatingCurrent) -> LocalDay {
        LocalDay(date: now, tzOffset: zone.secondsFromGMT(for: now))
    }

    public static func < (a: LocalDay, b: LocalDay) -> Bool { a.index < b.index }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// Local midnight of this day expressed as if it were UTC (for formatting with a UTC formatter).
    public var utcDate: Date { Date(timeIntervalSince1970: Double(index) * 86400) }

    public var components: (year: Int, month: Int, day: Int) {
        let c = Self.utc.dateComponents([.year, .month, .day], from: utcDate)
        return (c.year!, c.month!, c.day!)
    }

    /// 1 = Sunday … 7 = Saturday.
    public var weekday: Int { Self.utc.component(.weekday, from: utcDate) }

    public func adding(_ days: Int) -> LocalDay { LocalDay(index: index + days) }

    public func weekStart(firstWeekday: Int) -> LocalDay { adding(-((weekday - firstWeekday + 7) % 7)) }

    public var monthStart: LocalDay {
        let c = components
        return LocalDay(year: c.year, month: c.month, day: 1)
    }

    public var monthEnd: LocalDay {
        let c = components
        return LocalDay(year: c.year, month: c.month + 1, day: 1).adding(-1)
    }

    /// Noon of this day in `calendar` (for charts and pickers; noon avoids DST edges).
    public func localNoon(in calendar: Calendar = .current) -> Date {
        let c = components
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) ?? utcDate
    }
}

public extension ClosedRange where Bound == LocalDay {
    var days: [LocalDay] { (lowerBound.index...upperBound.index).map(LocalDay.init(index:)) }
}

/// One contiguous, non-overlapping interval on the timeline.
public struct Session: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var start: Date
    public var end: Date
    /// Seconds east of GMT when the session was recorded; decides which local day it belongs to.
    public var tzOffset: Int
    public var kind: SessionKind
    public var bundleID: String?
    public var appName: String?
    public var categoryID: Int64?
    public var projectID: Int64?
    public var source: TrackingSource
    public var edited: Bool
    public var note: String
    /// Why the session ended: switch, idle, pause, stop, lock, sleep, quit, recovered, …
    public var endReason: String

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public init(id: Int64 = 0, start: Date, end: Date, tzOffset: Int, kind: SessionKind,
                bundleID: String? = nil, appName: String? = nil, categoryID: Int64? = nil,
                projectID: Int64? = nil, source: TrackingSource = .automatic, edited: Bool = false,
                note: String = "", endReason: String = "") {
        self.id = id; self.start = start; self.end = end; self.tzOffset = tzOffset; self.kind = kind
        self.bundleID = bundleID; self.appName = appName; self.categoryID = categoryID
        self.projectID = projectID; self.source = source; self.edited = edited
        self.note = note; self.endReason = endReason
    }
}

public struct WorkCategory: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var kind: SessionKind  // work, nonwork or excluded
    public var builtin: Bool

    public init(id: Int64 = 0, name: String, kind: SessionKind, builtin: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.builtin = builtin
    }
}

/// A project doubles as a work profile: it can carry its own goals.
public struct Project: Identifiable, Equatable, Hashable, Sendable {
    public var id: Int64
    public var name: String

    public init(id: Int64 = 0, name: String) { self.id = id; self.name = name }
}

/// Application-specific tracking rule.
public struct AppRule: Identifiable, Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    public var categoryID: Int64
    /// Per-app idle threshold in seconds; nil = global default, 0 = never treat as idle.
    public var idleThreshold: Int?
    /// Work time in this app is filed under this project instead of the active one.
    public var projectID: Int64?

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, categoryID: Int64 = 4, idleThreshold: Int? = nil, projectID: Int64? = nil) {
        self.bundleID = bundleID; self.appName = appName; self.categoryID = categoryID
        self.idleThreshold = idleThreshold; self.projectID = projectID
    }
}

/// A versioned goal configuration. A new row is written whenever goals change, so past
/// periods keep being judged by the configuration that applied to them.
public struct GoalConfig: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var projectID: Int64?  // nil = overall
    public var effectiveFrom: LocalDay
    public var dailyHours: Double?
    public var weeklyHours: Double?
    public var monthlyHours: Double?
    public var weeklyDays: Int?
    /// Minimum work per day for it to count as a working day.
    public var minDayMinutes: Int
    /// Scheduled working days, 1 = Sunday … 7 = Saturday. The daily target applies on these.
    public var workingDays: Set<Int>

    public init(id: Int64 = 0, projectID: Int64? = nil, effectiveFrom: LocalDay, dailyHours: Double? = nil,
                weeklyHours: Double? = nil, monthlyHours: Double? = nil, weeklyDays: Int? = nil,
                minDayMinutes: Int = 30, workingDays: Set<Int> = [2, 3, 4, 5, 6]) {
        self.id = id; self.projectID = projectID; self.effectiveFrom = effectiveFrom
        self.dailyHours = dailyHours; self.weeklyHours = weeklyHours; self.monthlyHours = monthlyHours
        self.weeklyDays = weeklyDays; self.minDayMinutes = minDayMinutes; self.workingDays = workingDays
    }
}

public struct Compensation: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var effectiveFrom: LocalDay
    public var monthlyAmount: Double
    public var currency: String

    public init(id: Int64 = 0, effectiveFrom: LocalDay, monthlyAmount: Double, currency: String) {
        self.id = id; self.effectiveFrom = effectiveFrom; self.monthlyAmount = monthlyAmount; self.currency = currency
    }
}

public struct SleepSettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Target bedtime, minutes after midnight.
    public var bedtimeMinutes = 23 * 60
    public var leadMinutes = 30
    /// Weekdays (1 = Sunday) on which the bedtime occurs.
    public var days: Set<Int> = Set(1...7)
    public var sound = true
    public var snoozeMinutes = 10

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, enabled)
        bedtimeMinutes = c.value(.bedtimeMinutes, bedtimeMinutes)
        leadMinutes = c.value(.leadMinutes, leadMinutes)
        days = c.value(.days, days)
        sound = c.value(.sound, sound)
        snoozeMinutes = c.value(.snoozeMinutes, snoozeMinutes)
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var mode = TrackingMode.automatic
    /// Automatic/hybrid tracking switched on (Stop turns it off until Start).
    public var autoEnabled = true
    /// Seconds without input before tracking pauses.
    public var idleThreshold = 300
    /// Count apps that have no rule as work. Never applies to browsers.
    public var unclassifiedIsWork = false
    public var menuBarDisplay = MenuBarDisplay.today
    /// 1 = Sunday … 7 = Saturday.
    public var firstWeekday = Calendar.current.firstWeekday
    public var activeProjectID: Int64?
    public var sleep = SleepSettings()
    public var lastBackupDay: Int?
    /// Count time as work while an AI coding agent (Claude Code, Codex) reports that it is working.
    public var countAgentWork = true
    /// Minutes without any sign of life after which a working agent is assumed to have stopped.
    public var agentQuietMinutes = 15

    public init() {}

    // Missing keys fall back to defaults so settings survive app upgrades.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.value(.mode, mode)
        autoEnabled = c.value(.autoEnabled, autoEnabled)
        idleThreshold = c.value(.idleThreshold, idleThreshold)
        unclassifiedIsWork = c.value(.unclassifiedIsWork, unclassifiedIsWork)
        menuBarDisplay = c.value(.menuBarDisplay, menuBarDisplay)
        firstWeekday = c.value(.firstWeekday, firstWeekday)
        activeProjectID = c.value(.activeProjectID, activeProjectID)
        sleep = c.value(.sleep, sleep)
        lastBackupDay = c.value(.lastBackupDay, lastBackupDay)
        countAgentWork = c.value(.countAgentWork, countAgentWork)
        agentQuietMinutes = c.value(.agentQuietMinutes, agentQuietMinutes)
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}

/// Browsers are never auto-classified as work: WorkPulse does not read tabs or URLs,
/// so it cannot tell work browsing from anything else.
public enum Browsers {
    public static let bundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.canary",
        "org.chromium.Chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "com.duckduckgo.macos.browser",
        "app.zen-browser.zen", "com.openai.atlas",
    ]

    public static func isBrowser(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }
}
