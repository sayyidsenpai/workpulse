import XCTest
@testable import WorkPulseCore

final class AnalyticsTests: XCTestCase {
    private let h = 3600.0

    // MARK: Time interval calculations

    func testSessionCrossingMidnightIsSplitBetweenDays() {
        let s = Session(start: at(monday, 23), end: at(monday.adding(1), 1.5), tzOffset: 0, kind: .work)
        let slices = Aggregator.split(s)
        XCTAssertEqual(slices.map(\.day), [monday, monday.adding(1)])
        XCTAssertEqual(slices[0].seconds, 1 * h, accuracy: 1e-6)
        XCTAssertEqual(slices[1].seconds, 1.5 * h, accuracy: 1e-6)

        let totals = Aggregator.dayTotals([s])
        XCTAssertEqual(totals[monday]?.work ?? 0, 1 * h, accuracy: 1e-6)
        XCTAssertEqual(totals[monday.adding(1)]?.work ?? 0, 1.5 * h, accuracy: 1e-6)
    }

    func testMultiDaySessionCoversEveryDay() {
        let s = Session(start: at(monday, 22), end: at(monday.adding(2), 2), tzOffset: 0, kind: .idle)
        let slices = Aggregator.split(s)
        XCTAssertEqual(slices.map { $0.seconds / h }, [2, 24, 2])
        XCTAssertEqual(slices.reduce(0) { $0 + $1.seconds }, s.duration, accuracy: 1e-6)
    }

    func testDaysFollowTheTimeZoneTheWorkWasRecordedIn() {
        // 23:30–00:30 in UTC+9. In UTC this is entirely on one day; locally it straddles midnight.
        let tokyo = 9 * 3600
        let s = Session(start: at(monday, 23.5, tz: tokyo), end: at(monday.adding(1), 0.5, tz: tokyo), tzOffset: tokyo, kind: .work)
        let totals = Aggregator.dayTotals([s])
        XCTAssertEqual(totals[monday]?.work ?? 0, 0.5 * h, accuracy: 1e-6)
        XCTAssertEqual(totals[monday.adding(1)]?.work ?? 0, 0.5 * h, accuracy: 1e-6)

        // A negative offset: 20:00–21:00 in UTC-8 stays on its local day although UTC is already tomorrow.
        let pacific = -8 * 3600
        let evening = makeSession(monday, 20, 21, tz: pacific)
        XCTAssertEqual(Aggregator.split(evening).map(\.day), [monday])
        XCTAssertEqual(LocalDay(date: evening.start, tzOffset: 0), monday.adding(1))
    }

    func testDaylightSavingDayLengthIsHandledByRecordedOffsets() {
        // Spring forward: the engine starts a new session when the UTC offset changes, so the
        // local day simply has 23 real hours on the timeline.
        let before = Session(start: at(monday, 0, tz: 3600), end: at(monday, 2, tz: 3600), tzOffset: 3600, kind: .work)
        let after = Session(start: before.end, end: before.end.addingTimeInterval(21 * h), tzOffset: 7200, kind: .work)
        let totals = Aggregator.dayTotals([before, after])
        XCTAssertEqual(totals[monday]?.work ?? 0, 23 * h, accuracy: 1e-6)
        XCTAssertEqual(totals.count, 1)
    }

    func testKindsAreKeptApart() {
        let totals = Aggregator.dayTotals([
            makeSession(monday, 9, 12), makeSession(monday, 12, 13, kind: .nonwork),
            makeSession(monday, 13, 13.5, kind: .idle), makeSession(monday, 13.5, 13.75, kind: .excluded),
        ])[monday]!
        XCTAssertEqual(totals.work, 3 * h, accuracy: 1e-6)
        XCTAssertEqual(totals.nonwork, 1 * h, accuracy: 1e-6)
        XCTAssertEqual(totals.active, 4 * h, accuracy: 1e-6)
        XCTAssertEqual(totals.idle, 0.5 * h, accuracy: 1e-6)
        XCTAssertEqual(totals.excluded, 0.25 * h, accuracy: 1e-6)
    }

    // MARK: Calendar

    func testLocalDayCalendarMaths() {
        XCTAssertEqual(monday.weekday, 2)
        XCTAssertEqual(monday.adding(6).weekday, 1)
        XCTAssertEqual(monday.adding(3).weekStart(firstWeekday: 2), monday)
        XCTAssertEqual(monday.weekStart(firstWeekday: 1), monday.adding(-1), "weeks may start on Sunday")
        XCTAssertEqual(monday.weekStart(firstWeekday: 7), monday.adding(-2), "or on Saturday")

        let leap = LocalDay(year: 2024, month: 2, day: 10)
        XCTAssertEqual(leap.monthStart, LocalDay(year: 2024, month: 2, day: 1))
        XCTAssertEqual(leap.monthEnd.components.day, 29)
        XCTAssertEqual(LocalDay(year: 2023, month: 12, day: 31).monthEnd, LocalDay(year: 2023, month: 12, day: 31))
        XCTAssertEqual(LocalDay(year: 2023, month: 12, day: 31).adding(1).components.year, 2024)
        XCTAssertEqual(Period.week.range(containing: monday.adding(2), firstWeekday: 2), monday...monday.adding(6))
        XCTAssertEqual(Period.month.range(containing: monday, firstWeekday: 2).days.count, 31)
    }

    // MARK: Weekly and monthly aggregation

    func testWeeklyAndMonthlyAggregation() {
        let sessions = [
            makeSession(monday, 9, 13),                       // week 1: 4 h
            makeSession(monday.adding(2), 9, 12),             // week 1: 3 h
            makeSession(monday.adding(6), 23, 25),            // Sunday 23:00 → Monday 01:00: 1 h each week
            makeSession(monday.adding(8), 9, 14),             // week 2: 5 h
            makeSession(LocalDay(year: 2024, month: 3, day: 31), 22, 26),  // 2 h in March, 2 h in April
        ]
        let totals = Aggregator.dayTotals(sessions)
        let march = Period.month.range(containing: monday, firstWeekday: 2)

        let weeks = Aggregator.trend(totals, in: monday...monday.adding(13), by: .week, firstWeekday: 2)
        XCTAssertEqual(weeks.map(\.start), [monday, monday.adding(7)])
        XCTAssertEqual(weeks.map { $0.seconds / h }, [8, 6])

        XCTAssertEqual(Aggregator.sum(totals, in: march).work / h, 16, accuracy: 1e-6)
        let months = Aggregator.trend(totals, in: march.lowerBound...march.upperBound.adding(1), by: .month, firstWeekday: 2)
        XCTAssertEqual(months.map { $0.seconds / h }, [16, 2])

        let days = Aggregator.trend(totals, in: monday...monday.adding(2), by: .day, firstWeekday: 2)
        XCTAssertEqual(days.map { $0.seconds / h }, [4, 0, 3], "empty days are present in the trend")
    }

    func testDistributionIsClippedToTheRange() {
        var xcode = makeSession(monday, 22, 26)
        xcode.appName = "Xcode"
        var mail = makeSession(monday, 9, 10, kind: .nonwork)
        mail.appName = "Mail"
        let idle = makeSession(monday, 10, 20, kind: .idle)

        let apps = Aggregator.distribution([xcode, mail, idle], in: monday...monday, kinds: [.work, .nonwork]) { $0.appName ?? "?" }
        XCTAssertEqual(apps.map(\.key), ["Xcode", "Mail"])
        XCTAssertEqual(apps.map { $0.seconds / h }, [2, 1], "only the part inside the range counts; idle is not app time")
    }

    // MARK: Working days and goals

    func testWorkingDayThreshold() {
        let config = GoalConfig(effectiveFrom: monday, minDayMinutes: 60)
        XCTAssertFalse(Goals.isWorkingDay(59 * 60, on: monday, configs: [config]))
        XCTAssertTrue(Goals.isWorkingDay(60 * 60, on: monday, configs: [config]))
        XCTAssertFalse(Goals.isWorkingDay(30, on: monday, configs: []), "without a configuration a day still needs a minute of work")
        XCTAssertTrue(Goals.isWorkingDay(60, on: monday, configs: []))

        let totals = Aggregator.dayTotals([makeSession(monday, 9, 9.5), makeSession(monday.adding(1), 9, 11), makeSession(monday.adding(2), 9, 13)])
        let stats = Aggregator.stats(totals, in: monday...monday.adding(6), configs: [config])
        XCTAssertEqual(stats.workingDays, 2)
        XCTAssertEqual(stats.work / h, 6.5, accuracy: 1e-6)
        XCTAssertEqual(stats.averagePerWorkingDay / h, 3, accuracy: 1e-6, "average is over days that counted")
    }

    func testGoalProgressAndRemaining() {
        let config = GoalConfig(effectiveFrom: monday, dailyHours: 6, weeklyHours: 20, monthlyHours: 80, weeklyDays: 3)
        let totals = Aggregator.dayTotals([makeSession(monday, 9, 13), makeSession(monday.adding(1), 9, 16)])
        func result(_ p: Period, _ day: LocalDay) -> PeriodResult {
            Goals.evaluate(p, containing: day, totals: totals, configs: [config], today: monday.adding(1), firstWeekday: 2)
        }

        let day = result(.day, monday)
        XCTAssertEqual(day.remainingSeconds ?? -1, 2 * h, accuracy: 1e-6)
        XCTAssertEqual(day.fraction ?? -1, 4.0 / 6.0, accuracy: 1e-6)
        XCTAssertEqual(day.achieved, false)
        XCTAssertEqual(result(.day, monday.adding(1)).achieved, true)
        XCTAssertEqual(result(.day, monday.adding(1)).remainingSeconds, 0)

        let week = result(.week, monday)
        XCTAssertEqual(week.workSeconds / h, 11, accuracy: 1e-6)
        XCTAssertEqual(week.remainingSeconds ?? -1, 9 * h, accuracy: 1e-6)
        XCTAssertEqual(week.workingDays, 2)
        XCTAssertEqual(week.daysTarget, 3)
        XCTAssertEqual(week.achieved, false)

        let month = result(.month, monday)
        XCTAssertEqual(month.targetSeconds, 80 * h)
        XCTAssertEqual(month.remainingSeconds ?? -1, 69 * h, accuracy: 1e-6)
    }

    func testWeekNeedsBothHoursAndDaysWhenBothAreSet() {
        let config = GoalConfig(effectiveFrom: monday, weeklyHours: 10, weeklyDays: 3, minDayMinutes: 30)
        let twoLongDays = Aggregator.dayTotals([makeSession(monday, 8, 14), makeSession(monday.adding(1), 8, 14)])
        let result = Goals.evaluate(.week, containing: monday, totals: twoLongDays, configs: [config], today: monday.adding(6), firstWeekday: 2)
        XCTAssertEqual(result.achieved, false, "hours met, but only two working days")

        let noGoals = Goals.evaluate(.week, containing: monday, totals: twoLongDays, configs: [], today: monday.adding(6), firstWeekday: 2)
        XCTAssertNil(noGoals.achieved, "goals are optional")
        XCTAssertNil(noGoals.targetSeconds)
        XCTAssertEqual(noGoals.workingDays, 2)
    }

    func testWorkingDaysAreConfigurableFromOneToSeven() {
        let totals = Aggregator.dayTotals((0..<7).map { makeSession(monday.adding($0), 9, 11) })
        func week(days: Int, schedule: Set<Int>) -> PeriodResult {
            let config = GoalConfig(effectiveFrom: monday, dailyHours: 2, weeklyDays: days, workingDays: schedule)
            return Goals.evaluate(.week, containing: monday, totals: totals, configs: [config], today: monday.adding(6), firstWeekday: 2)
        }
        XCTAssertEqual(week(days: 7, schedule: Set(1...7)).achieved, true, "a seven-day week is a valid goal")
        XCTAssertEqual(week(days: 7, schedule: Set(1...7)).workingDays, 7)
        XCTAssertEqual(week(days: 1, schedule: [4]).achieved, true)

        // The daily target only applies on scheduled working days.
        let weekdaysOnly = GoalConfig(effectiveFrom: monday, dailyHours: 2, workingDays: [2, 3, 4, 5, 6])
        let saturday = Goals.evaluate(.day, containing: monday.adding(5), totals: totals, configs: [weekdaysOnly], today: monday.adding(6), firstWeekday: 2)
        XCTAssertNil(saturday.targetSeconds)
        let friday = Goals.evaluate(.day, containing: monday.adding(4), totals: totals, configs: [weekdaysOnly], today: monday.adding(6), firstWeekday: 2)
        XCTAssertEqual(friday.achieved, true)
    }

    func testChangingAGoalDoesNotRewriteHistory() {
        let week1 = monday, week3 = monday.adding(14)
        let totals = Aggregator.dayTotals([
            makeSession(week1, 8, 14), makeSession(week1.adding(1), 8, 14),   // 12 h
            makeSession(week3, 8, 14), makeSession(week3.adding(1), 8, 14),   // 12 h
        ])
        let original = GoalConfig(effectiveFrom: week1, weeklyHours: 10, minDayMinutes: 30)
        func history(_ configs: [GoalConfig]) -> [PeriodResult] {
            Goals.history(.week, in: week1...week3.adding(6), totals: totals, configs: configs, today: week3.adding(6), firstWeekday: 2)
        }

        let before = history([original])
        XCTAssertEqual(before.map(\.achieved), [true, false, true])

        // Raise the target (and the working-day minimum) starting in week 3.
        let raised = GoalConfig(effectiveFrom: week3, weeklyHours: 40, minDayMinutes: 480)
        let after = history([original, raised])
        XCTAssertEqual(after[0], before[0], "week 1 is judged by the goal that applied then")
        XCTAssertEqual(after[0].targetSeconds, 10 * h)
        XCTAssertEqual(after[0].workingDays, 2)
        XCTAssertEqual(after[2].targetSeconds, 40 * h)
        XCTAssertEqual(after[2].achieved, false)
        XCTAssertEqual(after[2].workingDays, 0, "6 h days no longer count under the new 8 h minimum")
        XCTAssertEqual(after.map(\.workSeconds), before.map(\.workSeconds), "recorded time never changes")
        XCTAssertNil(Goals.config(on: week1.adding(-1), projectID: nil, in: [original, raised]), "no goal applied before the first one")
    }

    func testProfilesHaveIndependentGoals() {
        let sessions = [makeSession(monday, 9, 12, project: 1), makeSession(monday, 13, 14, project: 2), makeSession(monday, 15, 16)]
        let configs = [
            GoalConfig(projectID: nil, effectiveFrom: monday, dailyHours: 8),
            GoalConfig(projectID: 1, effectiveFrom: monday, dailyHours: 2),
        ]
        func day(_ project: Int64?) -> PeriodResult {
            let totals = Aggregator.dayTotals(sessions) { project == nil || $0.projectID == project }
            return Goals.evaluate(.day, containing: monday, totals: totals, configs: configs, projectID: project, today: monday, firstWeekday: 2)
        }
        XCTAssertEqual(day(nil).workSeconds / h, 5, accuracy: 1e-6)
        XCTAssertEqual(day(nil).achieved, false)
        XCTAssertEqual(day(1).workSeconds / h, 3, accuracy: 1e-6)
        XCTAssertEqual(day(1).achieved, true)
        XCTAssertNil(day(2).achieved, "a profile without goals has none")
    }

    // MARK: Compensation

    func testCompensationCalculations() {
        XCTAssertEqual(Pay.hourly(monthlyAmount: 4000, workSeconds: 100 * h) ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(Pay.hourly(monthlyAmount: 4000, workSeconds: 160 * h) ?? 0, 25, accuracy: 1e-9)
        XCTAssertNil(Pay.hourly(monthlyAmount: 4000, workSeconds: 0), "no hours, no rate; never divide by zero")

        let jan = LocalDay(year: 2024, month: 1, day: 1), apr = LocalDay(year: 2024, month: 4, day: 1), jul = LocalDay(year: 2024, month: 7, day: 1)
        let entries = [
            Compensation(effectiveFrom: jan, monthlyAmount: 3000, currency: "USD"),
            Compensation(effectiveFrom: apr, monthlyAmount: 3500, currency: "EUR"),
            Compensation(effectiveFrom: jul, monthlyAmount: 0, currency: "EUR"),
        ]
        XCTAssertNil(Pay.entry(on: jan.adding(-1), in: entries))
        XCTAssertEqual(Pay.entry(on: monday.monthEnd, in: entries)?.monthlyAmount, 3000, "March still uses the January amount")
        XCTAssertEqual(Pay.entry(on: apr.monthEnd, in: entries)?.currency, "EUR")
        XCTAssertNil(Pay.entry(on: jul.monthEnd, in: entries), "a zero amount ends compensation")
        XCTAssertNil(Pay.entry(on: monday, in: []), "compensation is optional")
    }

    // MARK: CSV

    func testCSVExport() {
        XCTAssertEqual(CSV.field("plain"), "plain")
        XCTAssertEqual(CSV.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.field("=SUM(A1)"), "'=SUM(A1)", "formulas are neutralised")

        var s = makeSession(monday, 9, 10.5, project: 7, tz: 3600)
        s.id = 3
        s.appName = "Xcode"
        s.categoryID = 1
        s.note = "review, part 1"
        let csv = CSV.sessions([s], categories: [1: "Work"], projects: [7: "Apollo"])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1], "3,2024-03-04T09:00:00+01:00,2024-03-04T10:30:00+01:00,5400,work,Xcode,,Work,Apollo,automatic,no,,\"review, part 1\"")

        let totals = Aggregator.dayTotals([s])
        // Monday counts by Fixed hours (1h 30m outside the work hours), Tuesday by Flexible (no daily overtime).
        let daily = CSV.daily(totals, in: monday...monday.adding(1), isWorkingDay: { _, work in work >= 3600 },
                              rule: { $0 == monday ? .fixed : .flexible }, overtime: { $0 == monday ? 5400 : nil })
        XCTAssertEqual(daily.split(separator: "\n").map(String.init), [
            "date,work_hours,nonwork_hours,active_hours,idle_hours,excluded_hours,working_day,overtime_rule,overtime_hours",
            "2024-03-04,1.50,0.00,1.50,0.00,0.00,yes,fixed,1.50",
            "2024-03-05,0.00,0.00,0.00,0.00,0.00,no,flexible,",
        ])
    }

    // MARK: Sleep reminder scheduling

    func testSleepReminderTriggers() {
        var s = SleepSettings()
        XCTAssertTrue(SleepSchedule.triggers(s).isEmpty, "disabled by default")

        s.enabled = true
        XCTAssertEqual(SleepSchedule.triggers(s).count, 7)
        XCTAssertEqual(SleepSchedule.triggers(s).first, ReminderTrigger(weekday: 1, hour: 22, minute: 30))

        s.days = Set(2...6)                  // weekdays
        XCTAssertEqual(SleepSchedule.triggers(s).map(\.weekday), [2, 3, 4, 5, 6])

        s.leadMinutes = 0
        XCTAssertEqual(SleepSchedule.triggers(s).first, ReminderTrigger(weekday: 2, hour: 23, minute: 0))

        // Bedtime 00:15 on Monday with a 30-minute lead fires on Sunday at 23:45.
        s.days = [2]
        s.bedtimeMinutes = 15
        s.leadMinutes = 30
        XCTAssertEqual(SleepSchedule.triggers(s), [ReminderTrigger(weekday: 1, hour: 23, minute: 45)])
        s.days = [1]                         // Sunday wraps to Saturday
        XCTAssertEqual(SleepSchedule.triggers(s), [ReminderTrigger(weekday: 7, hour: 23, minute: 45)])
    }

    func testNextSleepReminder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var s = SleepSettings()
        s.enabled = true
        s.days = [2, 4]                      // Monday and Wednesday, 22:30
        XCTAssertEqual(SleepSchedule.nextFire(after: at(monday, 21), settings: s, calendar: calendar), at(monday, 22.5))
        XCTAssertEqual(SleepSchedule.nextFire(after: at(monday, 22.6), settings: s, calendar: calendar), at(monday.adding(2), 22.5))
        XCTAssertEqual(SleepSchedule.nextFire(after: at(monday.adding(2), 23), settings: s, calendar: calendar), at(monday.adding(7), 22.5))
        s.enabled = false
        XCTAssertNil(SleepSchedule.nextFire(after: at(monday, 21), settings: s, calendar: calendar))
    }
}
