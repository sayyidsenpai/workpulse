import XCTest
@testable import WorkPulseCore

/// How overtime counts: Flexible (work over the goal of the period) and Fixed hours (work outside the work hours).
final class OvertimeTests: XCTestCase {
    private let h = 3600.0
    /// Monday to Friday, 08.00 to 16.00.
    private let schedule = WorkSchedule(enabled: true, days: [2, 3, 4, 5, 6], startMinutes: 8 * 60, endMinutes: 16 * 60)

    private func goals(_ rule: OvertimeRule, daily: Double = 6) -> [GoalConfig] {
        [GoalConfig(effectiveFrom: monday.adding(-60), dailyHours: daily, overtime: rule)]
    }

    /// Overtime of `periods` the way Reports computes it: the Fixed days from one pass over the sessions.
    private func overtime(_ periods: [PeriodResult], _ sessions: [Session], _ schedule: WorkSchedule, _ configs: [GoalConfig]) -> TimeInterval {
        Aggregator.overtime(of: periods, fixedByDay: Aggregator.fixedOvertimeByDay(sessions, configs: configs, current: schedule))
    }

    /// The daily CSV cell: nil on a Flexible day or without work hours.
    private func fixedOn(_ sessions: [Session], on day: LocalDay, configs: [GoalConfig], current: WorkSchedule) -> TimeInterval? {
        Goals.fixedHours(on: day, configs: configs, current: current) == nil
            ? nil : Aggregator.fixedOvertimeByDay(sessions, configs: configs, current: current)[day] ?? 0
    }

    private func week(_ sessions: [Session], _ configs: [GoalConfig]) -> PeriodResult {
        Goals.evaluate(.week, containing: monday, totals: Aggregator.dayTotals(sessions), configs: configs,
                       today: monday.adding(6), firstWeekday: 2)
    }

    func testFlexibleLongDayThenRestIsNotOvertime() {
        // One 14-hour Monday, nothing else: 14h of a 30h week. Fixed hours calls 6h of it overtime.
        let sessions = [makeSession(monday, 6, 20)]
        let flexible = week(sessions, goals(.flexible))
        XCTAssertEqual(flexible.overtimeRule, .flexible)
        XCTAssertEqual(overtime([flexible], sessions, schedule, goals(.flexible)), 0)

        let fixed = week(sessions, goals(.fixed))
        XCTAssertEqual(overtime([fixed], sessions, schedule, goals(.fixed)), 6 * h, accuracy: 1e-6)
    }

    func testFlexibleOvertimeIsWorkOverTheWeeklyGoal() {
        // 31h 12m in a week with a 30h goal: 1h 12m of overtime, wherever the hours were.
        let sessions = [makeSession(monday, 6, 20), makeSession(monday.adding(3), 8, 16), makeSession(monday.adding(4), 7, 16.2)]
        let result = week(sessions, goals(.flexible))
        XCTAssertEqual(result.targetSeconds ?? 0, 30 * h, accuracy: 1e-6)
        XCTAssertEqual(overtime([result], sessions, schedule, goals(.flexible)), 1.2 * h, accuracy: 1e-6)
    }

    func testFlexibleYearBalancesAcrossMonths() {
        // Month A 10h over its goal, month B 10h under: the two months together have no overtime.
        let a = PeriodResult(period: .month, range: monday...monday.adding(27), workSeconds: 130 * h, targetSeconds: 120 * h,
                             workingDays: 20, overtimeRule: .flexible)
        let b = PeriodResult(period: .month, range: monday.adding(28)...monday.adding(58), workSeconds: 110 * h, targetSeconds: 120 * h,
                             workingDays: 20, overtimeRule: .flexible)
        XCTAssertEqual(overtime([a], [], schedule, []), 10 * h)
        XCTAssertEqual(overtime([a, b], [], schedule, []), 0)
    }

    func testFlexibleWithoutGoalHasNoOvertime() {
        let sessions = [makeSession(monday, 6, 20)]
        let configs = [GoalConfig(effectiveFrom: monday.adding(-60), overtime: .flexible)]
        let result = week(sessions, configs)
        XCTAssertNil(result.targetSeconds)
        XCTAssertFalse(Aggregator.overtimeApplies(to: [result], schedule: schedule, configs: configs))
        XCTAssertEqual(overtime([result], sessions, schedule, configs), 0)
    }

    func testFixedHoursNeedWorkHours() {
        let sessions = [makeSession(monday, 6, 20)]
        let result = week(sessions, goals(.fixed))
        XCTAssertTrue(Aggregator.overtimeApplies(to: [result], schedule: schedule, configs: goals(.fixed)))
        XCTAssertFalse(Aggregator.overtimeApplies(to: [result], schedule: WorkSchedule(), configs: goals(.fixed)))
        XCTAssertEqual(overtime([result], sessions, WorkSchedule(), goals(.fixed)), 0)
    }

    func testEachPeriodUsesTheRuleThatAppliedThen() {
        // Fixed hours until Wednesday, Flexible from Wednesday: the week is judged by the rule in force on its last day.
        let configs = [GoalConfig(effectiveFrom: monday.adding(-60), dailyHours: 6, overtime: .fixed),
                       GoalConfig(effectiveFrom: monday.adding(2), dailyHours: 6, overtime: .flexible)]
        let before = Goals.evaluate(.week, containing: monday.adding(-7), totals: [:], configs: configs, today: monday.adding(6), firstWeekday: 2)
        let current = week([], configs)
        XCTAssertEqual(before.overtimeRule, .fixed)
        XCTAssertEqual(current.overtimeRule, .flexible)
    }

    func testReachedIsTheMomentTheWorkPassedTheGoal() {
        let sessions = [makeSession(monday, 8, 12), makeSession(monday.adding(1), 9, 13), makeSession(monday.adding(1), 14, 18)]
        let range = monday...monday.adding(6)
        XCTAssertEqual(Aggregator.reached(10 * h, in: range, sessions: sessions), at(monday.adding(1), 16))
        XCTAssertNil(Aggregator.reached(13 * h, in: range, sessions: sessions))
        // Work before the range does not count toward it.
        XCTAssertEqual(Aggregator.reached(1 * h, in: monday.adding(1)...monday.adding(6), sessions: sessions), at(monday.adding(1), 10))
    }

    func testFixedHoursUseTheHoursOfTheirOwnVersion() {
        // 08.00 to 16.00 until Wednesday, then 10.00 to 18.00. Monday 08.00 to 17.00 has 1h of overtime
        // by its own hours, although today's hours would say 2h.
        let configs = [GoalConfig(effectiveFrom: monday.adding(-60), dailyHours: 6, overtime: .fixed, startMinutes: 8 * 60, endMinutes: 16 * 60),
                       GoalConfig(effectiveFrom: monday.adding(2), dailyHours: 6, overtime: .fixed, startMinutes: 10 * 60, endMinutes: 18 * 60)]
        var today = schedule
        today.startMinutes = 10 * 60
        today.endMinutes = 18 * 60
        let sessions = [makeSession(monday, 8, 17), makeSession(monday.adding(3), 8, 17)]
        XCTAssertEqual(fixedOn(sessions, on: monday, configs: configs, current: today) ?? -1, 1 * h, accuracy: 1e-6)
        XCTAssertEqual(fixedOn(sessions, on: monday.adding(3), configs: configs, current: today) ?? -1, 2 * h, accuracy: 1e-6)
        let result = week(sessions, configs)
        XCTAssertEqual(overtime([result], sessions, today, configs), 3 * h, accuracy: 1e-6)
        // A version without stored hours (saved before 1.1) uses the current hours.
        XCTAssertEqual(fixedOn(sessions, on: monday, configs: goals(.fixed), current: today) ?? -1, 2 * h, accuracy: 1e-6)
    }

    func testDailyOvertimeIsEmptyOnFlexibleDaysAndWithoutHours() {
        let sessions = [makeSession(monday, 6, 20)]
        XCTAssertNil(fixedOn(sessions, on: monday, configs: goals(.flexible), current: schedule))
        XCTAssertNil(fixedOn(sessions, on: monday, configs: goals(.fixed), current: WorkSchedule()))
        XCTAssertEqual(fixedOn(sessions, on: monday, configs: goals(.fixed), current: schedule) ?? -1, 6 * h, accuracy: 1e-6)
    }

    func testLiveWorkTurnsIntoFlexibleOvertimeWhenTheWeekPassesItsGoal() throws {
        // A Flexible week with a 3h 30m goal (30 minutes on each of 7 days) and 3h 20m already done.
        let store = try Store()
        try store.saveRule(AppRule(bundleID: "com.apple.dt.Xcode", appName: "Xcode", categoryID: Store.workID))
        let configs = [GoalConfig(effectiveFrom: monday.adding(-60), dailyHours: 0.5, workingDays: Set(1...7), overtime: .flexible)]
        try store.insert(makeSession(monday, 1, 4 + 1.0 / 3))
        let time = FakeTime(at(monday, 9))
        let engine = TrackingEngine(store: store, time: time)
        engine.recover()
        engine.appActivated(.init(bundleID: "com.apple.dt.Xcode", name: "Xcode"))

        var states: [(minute: Int, headline: Headline)] = []
        var reachedAt: Date?
        for minute in 1...20 {
            time.advance(60)
            engine.checkpoint()
            let sessions = try store.sessions()
            let week = Goals.evaluate(.week, containing: monday, totals: Aggregator.dayTotals(sessions), configs: configs,
                                      today: monday, firstWeekday: 2)
            let overtime = Goals.inOvertime(week: week, profile: engine.settings.profile, outsideHours: engine.isOvertime)
            states.append((minute, Headline(status: engine.status, overtime: overtime, agent: false, dayOff: false)))
            reachedAt = week.targetSeconds.flatMap { Aggregator.reached($0, in: week.range, sessions: sessions) }
        }
        // The goal is reached after 10 minutes of live work; from the next minute the state is overtime.
        XCTAssertEqual(states.filter { $0.headline == .tracking }.map(\.minute), Array(1...10))
        XCTAssertEqual(states.filter { $0.headline == .overtime }.map(\.minute), Array(11...20))
        XCTAssertEqual(reachedAt?.timeIntervalSince1970 ?? 0, at(monday, 9 + 10.0 / 60).timeIntervalSince1970, accuracy: 1)

        // Personal is never overtime, also over the goal.
        engine.endWork()
        let week = Goals.evaluate(.week, containing: monday, totals: Aggregator.dayTotals(try store.sessions()), configs: configs,
                                  today: monday, firstWeekday: 2)
        XCTAssertFalse(Goals.inOvertime(week: week, profile: engine.settings.profile, outsideHours: engine.isOvertime))
    }

    func testOlderVersionsKeepTheHoursOfTheUpgrade() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = try Database(path: directory.appendingPathComponent("workpulse.sqlite").path)
        var settings = AppSettings()
        settings.schedule = WorkSchedule(enabled: true, days: [2, 3, 4, 5, 6], startMinutes: 9 * 60, endMinutes: 17 * 60)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try old.exec("""
        CREATE TABLE goals(id INTEGER PRIMARY KEY, project_id INTEGER, effective_from INTEGER NOT NULL,
            daily_hours REAL, weekly_hours REAL, monthly_hours REAL, weekly_days INTEGER,
            min_day_minutes INTEGER NOT NULL, working_days INTEGER NOT NULL);
        INSERT INTO goals(effective_from, daily_hours, min_day_minutes, working_days) VALUES (\(monday.index - 60), 6, 30, 62);
        CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO settings(key, value) VALUES ('app', '\(json)');
        """)
        old.close()

        let store = try Store(directory: directory)
        defer { store.close() }
        let configs = try store.goalConfigs()
        XCTAssertEqual(configs.map(\.startMinutes), [9 * 60])
        // Later the hours change to 08.00 to 16.00: Monday 08.00 to 17.00 before the change still has 1h of overtime (8 to 9).
        var now = settings.schedule
        now.startMinutes = 8 * 60
        now.endMinutes = 16 * 60
        XCTAssertEqual(fixedOn([makeSession(monday, 8, 17)], on: monday, configs: configs, current: now) ?? -1, 1 * h, accuracy: 1e-6)
    }

    func testZeroGoalHasNoFlexibleOvertime() {
        // A week of days off: the goal is 0, so 5h of work there is not overtime (the popover agrees).
        let week = PeriodResult(period: .week, range: monday...monday.adding(6), workSeconds: 5 * h, targetSeconds: 0,
                                workingDays: 1, overtimeRule: .flexible)
        XCTAssertFalse(Aggregator.overtimeApplies(to: [week], schedule: schedule, configs: []))
        XCTAssertEqual(Aggregator.overtime(of: [week], fixedByDay: [:]), 0)
        XCTAssertFalse(Goals.inOvertime(week: week, profile: .work, outsideHours: false))
    }

    func testFixedWeekMatchesTheSumOfItsCSVDays() {
        // Flexible until Tuesday, Fixed from Wednesday: the Fixed week adds only its Fixed days, the same cells as the CSV.
        let configs = [GoalConfig(effectiveFrom: monday.adding(-60), dailyHours: 6, overtime: .flexible),
                       GoalConfig(effectiveFrom: monday.adding(2), dailyHours: 6, overtime: .fixed)]
        let sessions = (0..<5).map { makeSession(monday.adding($0), 7, 17) }
        let result = week(sessions, configs)
        XCTAssertEqual(result.overtimeRule, .fixed)
        let cells = (0..<7).compactMap { fixedOn(sessions, on: monday.adding($0), configs: configs, current: schedule) }
        XCTAssertNil(fixedOn(sessions, on: monday, configs: configs, current: schedule))
        XCTAssertEqual(overtime([result], sessions, schedule, configs), cells.reduce(0, +), accuracy: 1e-6)
        XCTAssertEqual(cells.reduce(0, +), 3 * 2 * h, accuracy: 1e-6)
    }

    func testGoalSoundPlaysOnlyWhenWorkReachesTheGoal() {
        var cue = GoalCue()
        XCTAssertFalse(cue.update(reached: true, flexible: false, target: 6 * h), "a goal reached before launch is silent")
        cue = GoalCue()
        XCTAssertFalse(cue.update(reached: false, flexible: false, target: 6 * h))
        XCTAssertTrue(cue.update(reached: true, flexible: false, target: 6 * h), "work reached the goal")
        XCTAssertFalse(cue.update(reached: true, flexible: false, target: 6 * h), "once")
        // The goal moves to the work: a change of rule, a lower goal, a day off. No sound.
        cue = GoalCue()
        _ = cue.update(reached: false, flexible: false, target: 6 * h)
        XCTAssertFalse(cue.update(reached: true, flexible: true, target: 30 * h))
        cue = GoalCue()
        _ = cue.update(reached: false, flexible: true, target: 30 * h)
        XCTAssertFalse(cue.update(reached: true, flexible: true, target: 24 * h))
        // After the change, work that reaches the new goal plays it again.
        _ = cue.update(reached: false, flexible: true, target: 30 * h)
        XCTAssertTrue(cue.update(reached: true, flexible: true, target: 30 * h))
    }

    func testResultOfAPeriodNeverSaysItFailed() {
        let week = monday...monday.adding(6)
        func result(_ work: Double, _ goal: Double?, days: Int? = nil, worked: Int = 5) -> PeriodResult {
            PeriodResult(period: .week, range: week, workSeconds: work * h, targetSeconds: goal.map { $0 * h }, workingDays: worked, daysTarget: days)
        }
        let after = monday.adding(7)
        XCTAssertEqual(result(30, 30).outcome(today: after), .reached)
        XCTAssertEqual(result(23.1, 30).outcome(today: after), .share(0.77))
        XCTAssertEqual(result(20, 30).outcome(today: monday.adding(6)), .open(left: 10 * h))
        // Hours reached, days goal (older settings) not: the days, not "100% of goal".
        XCTAssertEqual(result(30, 30, days: 5, worked: 4).outcome(today: after), .days(worked: 4, goal: 5))
        XCTAssertEqual(result(30, 30, days: 5, worked: 4).outcome(today: monday.adding(3)), .open(left: nil))
        XCTAssertEqual(result(10, nil, days: 5, worked: 2).outcome(today: after), .days(worked: 2, goal: 5))
        XCTAssertEqual(result(10, nil).outcome(today: after), .noGoal)
    }

    func testRuleIsStoredAndOlderRowsReadAsFixed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A database from before the choice existed: the goals table has no overtime column.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = try Database(path: directory.appendingPathComponent("workpulse.sqlite").path)
        try old.exec("""
        CREATE TABLE goals(id INTEGER PRIMARY KEY, project_id INTEGER, effective_from INTEGER NOT NULL,
            daily_hours REAL, weekly_hours REAL, monthly_hours REAL, weekly_days INTEGER,
            min_day_minutes INTEGER NOT NULL, working_days INTEGER NOT NULL);
        INSERT INTO goals(effective_from, daily_hours, min_day_minutes, working_days) VALUES (\(monday.index), 6, 30, 62);
        """)
        old.close()

        var store = try Store(directory: directory)
        XCTAssertEqual(try store.goalConfigs().map(\.overtime), [.fixed])
        try store.saveGoal(GoalConfig(effectiveFrom: monday.adding(7), dailyHours: 6, overtime: .flexible, startMinutes: 540, endMinutes: 1020))
        store.close()

        // Opening again does not add the columns twice, and both versions keep their rule and hours.
        store = try Store(directory: directory)
        let configs = try store.goalConfigs()
        XCTAssertEqual(configs.map(\.overtime), [.fixed, .flexible])
        // The version from before 1.1 was given the hours in force at the upgrade: none here (0 to 0).
        XCTAssertEqual(configs.map(\.startMinutes), [0, 540])
        XCTAssertEqual(configs.map(\.endMinutes), [0, 1020])
        store.close()
    }
}
