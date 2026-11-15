import Foundation

public struct DayTotals: Equatable, Sendable {
    public var work: TimeInterval = 0
    public var nonwork: TimeInterval = 0
    public var idle: TimeInterval = 0
    public var excluded: TimeInterval = 0

    public init() {}

    /// Time an application was in front and the user was present (work + non-work).
    public var active: TimeInterval { work + nonwork }

    mutating func add(_ kind: SessionKind, _ seconds: TimeInterval) {
        switch kind {
        case .work: work += seconds
        case .nonwork: nonwork += seconds
        case .idle: idle += seconds
        case .excluded: excluded += seconds
        }
    }
}

public struct RangeStats: Equatable, Sendable {
    public var work: TimeInterval = 0
    public var active: TimeInterval = 0
    public var idle: TimeInterval = 0
    public var excluded: TimeInterval = 0
    public var workingDays = 0
    var workOnWorkingDays: TimeInterval = 0

    public init() {}

    public var averagePerWorkingDay: TimeInterval { workingDays > 0 ? workOnWorkingDays / Double(workingDays) : 0 }
}

public enum Period: String, CaseIterable, Sendable {
    case day, week, month

    public func range(containing day: LocalDay, firstWeekday: Int) -> ClosedRange<LocalDay> {
        switch self {
        case .day: return day...day
        case .week:
            let start = day.weekStart(firstWeekday: firstWeekday)
            return start...start.adding(6)
        case .month: return day.monthStart...day.monthEnd
        }
    }
}

/// The one place where sessions become totals. Dashboard, history, reports and exports all go
/// through these functions, so their numbers cannot disagree.
public enum Aggregator {
    /// Splits a session at local midnights, using the UTC offset recorded with it.
    public static func split(_ s: Session) -> [(day: LocalDay, seconds: TimeInterval)] {
        let offset = Double(s.tzOffset)
        var a = s.start.timeIntervalSince1970 + offset
        let b = s.end.timeIntervalSince1970 + offset
        var slices: [(day: LocalDay, seconds: TimeInterval)] = []
        while a < b {
            let day = Int((a / 86400).rounded(.down))
            let next = min(b, Double(day + 1) * 86400)
            slices.append((LocalDay(index: day), next - a))
            a = next
        }
        return slices
    }

    public static func dayTotals(_ sessions: [Session], where include: (Session) -> Bool = { _ in true }) -> [LocalDay: DayTotals] {
        var totals: [LocalDay: DayTotals] = [:]
        for s in sessions where include(s) {
            for slice in split(s) { totals[slice.day, default: DayTotals()].add(s.kind, slice.seconds) }
        }
        return totals
    }

    public static func sum(_ totals: [LocalDay: DayTotals], in range: ClosedRange<LocalDay>?) -> DayTotals {
        var out = DayTotals()
        for (day, t) in totals where range?.contains(day) ?? true {
            out.work += t.work; out.nonwork += t.nonwork; out.idle += t.idle; out.excluded += t.excluded
        }
        return out
    }

    public static func stats(_ totals: [LocalDay: DayTotals], in range: ClosedRange<LocalDay>, configs: [GoalConfig], projectID: Int64? = nil) -> RangeStats {
        var stats = RangeStats()
        for (day, t) in totals where range.contains(day) {
            stats.work += t.work; stats.active += t.active; stats.idle += t.idle; stats.excluded += t.excluded
            if Goals.isWorkingDay(t.work, on: day, configs: configs, projectID: projectID) {
                stats.workingDays += 1
                stats.workOnWorkingDays += t.work
            }
        }
        return stats
    }

    /// Time per key (application, category, project…), largest first, clipped to `range`.
    public static func distribution(_ sessions: [Session], in range: ClosedRange<LocalDay>?, kinds: Set<SessionKind>,
                                    key: (Session) -> String) -> [(key: String, seconds: TimeInterval)] {
        var sums: [String: TimeInterval] = [:]
        for s in sessions where kinds.contains(s.kind) {
            let seconds = split(s).filter { range?.contains($0.day) ?? true }.reduce(0) { $0 + $1.seconds }
            if seconds > 0 { sums[key(s), default: 0] += seconds }
        }
        return sums.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { (key: $0.key, seconds: $0.value) }
    }

    /// Work recorded from `start` on (a session that began earlier counts from `start`).
    public static func work(_ sessions: [Session], since start: Date) -> TimeInterval {
        sessions.filter { $0.kind == .work }.reduce(0) { $0 + max(0, $1.end.timeIntervalSince(max($1.start, start))) }
    }

    /// Overtime of goal periods (weeks or months), each by the rule that applied to it:
    /// Fixed hours, the Fixed overtime of its days (`fixedByDay`); Flexible, work over the goal.
    /// Flexible periods in one call balance each other, so a year is the work of the year over
    /// the goal of the year, not the sum of its months.
    public static func overtime(of periods: [PeriodResult], fixedByDay: [LocalDay: TimeInterval]) -> TimeInterval {
        var fixed: TimeInterval = 0, work: TimeInterval = 0, goal: TimeInterval = 0
        for p in periods {
            switch p.overtimeRule {
            case .fixed:
                fixed += p.range.days.reduce(0) { $0 + (fixedByDay[$1] ?? 0) }
            case .flexible:
                // No goal, or a goal of zero (a week of days off): nothing to be over, as in the popover.
                guard let target = p.targetSeconds, target > 0 else { continue }
                work += p.workSeconds
                goal += target
            }
        }
        return fixed + max(0, work - goal)
    }

    /// False when no rule can give overtime for these periods: Fixed hours without work hours,
    /// or Flexible without a goal.
    public static func overtimeApplies(to periods: [PeriodResult], schedule: WorkSchedule, configs: [GoalConfig]) -> Bool {
        periods.contains { p in
            p.overtimeRule == .fixed
                ? p.range.days.contains { Goals.fixedHours(on: $0, configs: configs, current: schedule) != nil }
                : (p.targetSeconds ?? 0) > 0
        }
    }

    /// Fixed hours overtime of each day whose own goal version counts by Fixed hours and has work
    /// hours (days without work are not in the result). One pass over the sessions, so a report of
    /// all time stays fast; Reports, the daily CSV and the period totals all read it.
    public static func fixedOvertimeByDay(_ sessions: [Session], configs: [GoalConfig], current: WorkSchedule) -> [LocalDay: TimeInterval] {
        var hours: [Int: WorkSchedule?] = [:]
        func hoursOn(_ day: Int) -> WorkSchedule? {
            if let known = hours[day] { return known }
            let found = Goals.fixedHours(on: LocalDay(index: day), configs: configs, current: current)
            hours[day] = found
            return found
        }
        var out: [LocalDay: TimeInterval] = [:]
        for s in sessions where s.kind == .work {
            let offset = Double(s.tzOffset)
            var a = s.start.timeIntervalSince1970 + offset
            let b = s.end.timeIntervalSince1970 + offset
            while a < b {
                let day = Int((a / 86400).rounded(.down))
                let next = min(b, Double(day + 1) * 86400)
                if let h = hoursOn(day) { out[LocalDay(index: day), default: 0] += (next - a) - h.overlap(localFrom: a, to: next) }
                a = next
            }
        }
        return out
    }

    /// The moment the work in `range` reached `seconds`; nil if it did not.
    public static func reached(_ seconds: TimeInterval, in range: ClosedRange<LocalDay>, sessions: [Session]) -> Date? {
        let lower = Double(range.lowerBound.index) * 86400, upper = Double(range.upperBound.index + 1) * 86400
        var total: TimeInterval = 0
        for s in sessions.filter({ $0.kind == .work }).sorted(by: { $0.start < $1.start }) {
            let offset = Double(s.tzOffset)
            let a = max(s.start.timeIntervalSince1970 + offset, lower), b = min(s.end.timeIntervalSince1970 + offset, upper)
            guard b > a else { continue }
            if total + (b - a) >= seconds { return Date(timeIntervalSince1970: a - offset + (seconds - total)) }
            total += b - a
        }
        return nil
    }

    /// Work time on `day` that is outside the work hours.
    public static func overtime(_ sessions: [Session], on day: LocalDay, schedule: WorkSchedule) -> TimeInterval {
        guard schedule.isUsable else { return 0 }
        let dayStart = Double(day.index) * 86400
        var total: TimeInterval = 0
        for s in sessions where s.kind == .work {
            let offset = Double(s.tzOffset)
            let a = max(s.start.timeIntervalSince1970 + offset, dayStart)
            let b = min(s.end.timeIntervalSince1970 + offset, dayStart + 86400)
            if b > a { total += (b - a) - schedule.overlap(localFrom: a, to: b) }
        }
        return total
    }

    /// Work time per day/week/month bucket across `range`, including empty buckets.
    public static func trend(_ totals: [LocalDay: DayTotals], in range: ClosedRange<LocalDay>, by period: Period,
                             firstWeekday: Int) -> [(start: LocalDay, seconds: TimeInterval)] {
        var sums: [LocalDay: TimeInterval] = [:]
        for day in range.days {
            sums[period.range(containing: day, firstWeekday: firstWeekday).lowerBound, default: 0] += totals[day]?.work ?? 0
        }
        return sums.sorted { $0.key < $1.key }.map { (start: $0.key, seconds: $0.value) }
    }
}

public struct PeriodResult: Equatable, Sendable {
    public var period: Period
    public var range: ClosedRange<LocalDay>
    public var workSeconds: TimeInterval
    public var targetSeconds: TimeInterval?
    /// Days with work (each day that reached the minimum counts, planned or not).
    public var workingDays: Int
    /// A days goal set by hand (older settings); nil for the derived goals.
    public var daysTarget: Int?
    /// Work days in the period by the schedule, without days off.
    public var plannedDays: Int?
    /// How overtime counts in this period: the rule of the goal version that judges it.
    public var overtimeRule: OvertimeRule = .fixed

    /// The number to show after "x of": the days goal, or else the planned work days.
    public var daysGoal: Int? { daysTarget ?? plannedDays }

    public var remainingSeconds: TimeInterval? { targetSeconds.map { max(0, $0 - workSeconds) } }
    public var fraction: Double? { targetSeconds.map { $0 > 0 ? min(1, workSeconds / $0) : 1 } }

    /// What the Result column says about the period. A finished period under its goal says how far
    /// the work came, never that it failed.
    public enum Outcome: Equatable, Sendable {
        case reached
        /// Not finished yet; the hours still to the goal (nil when only a days goal is left).
        case open(left: TimeInterval?)
        /// Finished under the hours goal: the share of the goal, below 1.
        case share(Double)
        /// Finished with the hours goal reached but a days goal (older settings) not reached.
        case days(worked: Int, goal: Int)
        case noGoal
    }

    public func outcome(today: LocalDay) -> Outcome {
        guard let achieved else { return .noGoal }
        if achieved { return .reached }
        if range.upperBound >= today { return .open(left: remainingSeconds.flatMap { $0 > 0 ? $0 : nil }) }
        if let share = fraction, share < 1 { return .share(share) }
        return .days(worked: workingDays, goal: daysTarget ?? workingDays)
    }

    /// nil when no target applied to the period; otherwise whether every configured target was met.
    public var achieved: Bool? {
        let checks = [targetSeconds.map { workSeconds >= $0 }, daysTarget.map { workingDays >= $0 }].compactMap { $0 }
        return checks.isEmpty ? nil : checks.allSatisfy { $0 }
    }
}

/// Goal evaluation. Goals only measure; nothing here can start, stop or alter tracking.
public enum Goals {
    /// The Work profile is in overtime now. Flexible: this week's work is over the weekly goal.
    /// Fixed hours: work outside the work hours (`outsideHours`, from the engine).
    public static func inOvertime(week: PeriodResult?, profile: Profile, outsideHours: Bool) -> Bool {
        guard let week, week.overtimeRule == .flexible else { return outsideHours }
        guard profile == .work, let target = week.targetSeconds, target > 0 else { return false }
        return week.workSeconds > target
    }

    /// The work hours that applied on `day`: those of the goal version in force then, with the
    /// current days off. Versions without stored hours use the current work hours.
    public static func schedule(on day: LocalDay, configs: [GoalConfig], current: WorkSchedule) -> WorkSchedule {
        guard let c = config(on: day, projectID: nil, in: configs), let start = c.startMinutes, let end = c.endMinutes else { return current }
        var hours = current
        hours.enabled = true
        hours.days = c.workingDays
        hours.startMinutes = start
        hours.endMinutes = end
        // ponytail: a window that began the evening before uses this day's hours; store the window per day if hours often change overnight.
        return hours
    }

    /// The work hours that judge `day` by Fixed hours; nil when Flexible applied that day (it
    /// counts by week and month, not by day) or when there were no work hours to compare with.
    public static func fixedHours(on day: LocalDay, configs: [GoalConfig], current: WorkSchedule) -> WorkSchedule? {
        guard config(on: day, projectID: nil, in: configs)?.overtime ?? .fixed == .fixed else { return nil }
        let hours = schedule(on: day, configs: configs, current: current)
        return hours.isUsable ? hours : nil
    }

    /// The goal version in force on `day` for a profile (nil = overall).
    public static func config(on day: LocalDay, projectID: Int64?, in configs: [GoalConfig]) -> GoalConfig? {
        configs.filter { $0.projectID == projectID && $0.effectiveFrom <= day }.max { $0.effectiveFrom < $1.effectiveFrom }
    }

    /// A day counts as worked once it reaches the minimum that applied on that day (at least a minute).
    public static func isWorkingDay(_ workSeconds: TimeInterval, on day: LocalDay, configs: [GoalConfig], projectID: Int64? = nil) -> Bool {
        let minimum = config(on: day, projectID: projectID, in: configs)?.minDayMinutes ?? 0
        return workSeconds >= max(60, Double(minimum) * 60)
    }

    /// Evaluates the day, week or month containing `day`. `totals` must already be filtered to the
    /// profile. The configuration used is the one in force on the period's last day (or today for
    /// the current period), so later goal changes never rewrite how past periods are judged.
    /// `isDayOff`: days off have no daily goal and do not count toward derived week and month goals.
    public static func evaluate(_ period: Period, containing day: LocalDay, totals: [LocalDay: DayTotals],
                                configs: [GoalConfig], projectID: Int64? = nil, today: LocalDay, firstWeekday: Int,
                                isDayOff: (LocalDay) -> Bool = { _ in false }) -> PeriodResult {
        let range = period.range(containing: day, firstWeekday: firstWeekday)
        let config = config(on: min(range.upperBound, today), projectID: projectID, in: configs)
        var work: TimeInterval = 0
        var workingDays = 0
        for d in range.days {
            let seconds = totals[d]?.work ?? 0
            work += seconds
            if isWorkingDay(seconds, on: d, configs: configs, projectID: projectID) { workingDays += 1 }
        }
        let planned = config.map { c in range.days.filter { c.workingDays.contains($0.weekday) && !isDayOff($0) }.count }
        // A week or month without its own goal takes the daily goal for each of its work days.
        let derived = config.flatMap { c in c.dailyHours.map { $0 * Double(planned ?? 0) } }
        let hours: Double?
        switch period {
        case .day: hours = config.flatMap { $0.workingDays.contains(day.weekday) && !isDayOff(day) ? $0.dailyHours : nil }
        case .week: hours = config?.weeklyHours ?? derived
        case .month: hours = config?.monthlyHours ?? derived
        }
        return PeriodResult(period: period, range: range, workSeconds: work, targetSeconds: hours.map { $0 * 3600 },
                            workingDays: workingDays, daysTarget: period == .week ? config?.weeklyDays : nil,
                            plannedDays: planned, overtimeRule: config?.overtime ?? .fixed)
    }

    /// Every week or month that touches `range`, oldest first.
    public static func history(_ period: Period, in range: ClosedRange<LocalDay>, totals: [LocalDay: DayTotals],
                               configs: [GoalConfig], projectID: Int64? = nil, today: LocalDay, firstWeekday: Int,
                               isDayOff: (LocalDay) -> Bool = { _ in false }) -> [PeriodResult] {
        var results: [PeriodResult] = []
        var day = range.lowerBound
        while day <= range.upperBound {
            let result = evaluate(period, containing: day, totals: totals, configs: configs, projectID: projectID,
                                  today: today, firstWeekday: firstWeekday, isDayOff: isDayOff)
            results.append(result)
            day = result.range.upperBound.adding(1)
        }
        return results
    }
}

/// Optional compensation maths. Purely descriptive: no tax, employment or currency assumptions.
public enum Pay {
    /// The compensation entry in force on `day`; a zero amount means "none".
    public static func entry(on day: LocalDay, in entries: [Compensation]) -> Compensation? {
        let entry = entries.filter { $0.effectiveFrom <= day }.max { $0.effectiveFrom < $1.effectiveFrom }
        return entry.flatMap { $0.monthlyAmount > 0 ? $0 : nil }
    }

    /// Monthly amount divided by the hours actually worked; nil until there is at least a minute of work.
    public static func hourly(monthlyAmount: Double, workSeconds: TimeInterval) -> Double? {
        workSeconds >= 60 ? monthlyAmount / (workSeconds / 3600) : nil
    }
}

public enum CSV {
    /// Quotes a text field and neutralises spreadsheet formula injection.
    public static func field(_ text: String) -> String {
        var v = text
        if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
        guard v.contains(where: { ",\"\n\r".contains($0) }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func timestamp(_ date: Date, offset: Int) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: offset)
        return f.string(from: date)
    }

    public static func sessions(_ sessions: [Session], categories: [Int64: String], projects: [Int64: String]) -> String {
        var lines = ["id,start,end,duration_seconds,kind,application,bundle_id,category,project,source,edited,end_reason,note"]
        for s in sessions {
            lines.append([
                String(s.id), timestamp(s.start, offset: s.tzOffset), timestamp(s.end, offset: s.tzOffset),
                String(Int(s.duration.rounded())), s.kind.rawValue, field(s.appName ?? ""), field(s.bundleID ?? ""),
                field(s.categoryID.flatMap { categories[$0] } ?? ""), field(s.projectID.flatMap { projects[$0] } ?? ""),
                s.source.rawValue, s.edited ? "yes" : "no", field(s.endReason), field(s.note),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One row per day: the aggregated report. `overtime` is the Fixed hours overtime of the day,
    /// or nil on a day that counts by the Flexible rule (its overtime belongs to the week and the
    /// month, so the cell stays empty). New columns go at the end, so older imports keep working.
    public static func daily(_ totals: [LocalDay: DayTotals], in range: ClosedRange<LocalDay>, isWorkingDay: (LocalDay, TimeInterval) -> Bool,
                             rule: (LocalDay) -> OvertimeRule, overtime: (LocalDay) -> TimeInterval?) -> String {
        var lines = ["date,work_hours,nonwork_hours,active_hours,idle_hours,excluded_hours,working_day,overtime_rule,overtime_hours"]
        func hours(_ seconds: TimeInterval) -> String { String(format: "%.2f", seconds / 3600) }
        for day in range.days {
            let t = totals[day] ?? DayTotals()
            let c = day.components
            lines.append([
                String(format: "%04d-%02d-%02d", c.year, c.month, c.day), hours(t.work), hours(t.nonwork), hours(t.active),
                hours(t.idle), hours(t.excluded), isWorkingDay(day, t.work) ? "yes" : "no",
                rule(day).rawValue, overtime(day).map(hours) ?? "",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
