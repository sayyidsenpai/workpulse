import XCTest
@testable import WorkPulseCore

/// Work and Personal profiles, work hours, overtime, the "Is this work?" evidence, derived goals.
final class ProfileTests: XCTestCase {
    typealias App = TrackingEngine.FrontApp

    var store: Store!
    var time: FakeTime!
    var engine: TrackingEngine!
    var hoursEnded = 0
    var hoursStarted = 0
    let xcode = App(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    let weekdays: Set<Int> = [2, 3, 4, 5, 6]

    override func setUpWithError() throws {
        store = try Store()
        try store.saveRule(AppRule(bundleID: xcode.bundleID, appName: xcode.name, categoryID: Store.workID))
        try boot(at: 9)
    }

    /// A fresh engine on the same store, as after a relaunch, at `hour` on Monday.
    private func boot(at hour: Double, day: LocalDay = monday) throws {
        time = FakeTime(at(day, hour))
        engine = TrackingEngine(store: store, time: time)
        engine.recover()
        hoursEnded = 0
        hoursStarted = 0
        engine.onWorkHoursEnded = { [unowned self] in hoursEnded += 1 }
        engine.onWorkHoursStarted = { [unowned self] in hoursStarted += 1 }
    }

    private func useWorkHours(_ start: Int = 8, _ end: Int = 16) {
        engine.updateSettings { $0.schedule = WorkSchedule(enabled: true, days: weekdays, startMinutes: start * 60, endMinutes: end * 60) }
    }

    private func all() throws -> [Session] { try store.sessions() }

    // MARK: Profiles

    func testPersonalCountsNoWorkButKeepsTheApplication() throws {
        engine.endWork()
        XCTAssertEqual(engine.status, .personal)
        engine.appActivated(xcode)
        time.advance(600)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map(\.kind), [.nonwork])
        XCTAssertEqual(sessions[0].appName, "Xcode")
        XCTAssertEqual(sessions[0].categoryID, Store.workID)
        XCTAssertEqual(total(sessions, .work), 0)
    }

    func testStartWorkCountsFromNowOnly() throws {
        engine.endWork()
        engine.appActivated(xcode)
        time.advance(600)
        engine.startWork()
        XCTAssertEqual(engine.status, .tracking(.work))
        time.advance(300)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(total(sessions, .nonwork), 600, accuracy: 0.001)
        XCTAssertEqual(total(sessions, .work), 300, accuracy: 0.001)
        assertNoOverlap(sessions)
    }

    func testProfileSurvivesRelaunch() throws {
        engine.endWork()
        engine.shutdown()
        try boot(at: 10)
        XCTAssertEqual(engine.status, .personal)
    }

    func testAgentWorkIsNotCountedInPersonal() throws {
        engine.endWork()
        engine.appActivated(slack)
        engine.setAgent("Claude Code")
        time.advance(600)
        engine.shutdown()
        XCTAssertEqual(total(try all(), .work), 0)
    }

    func testOldStoppedStateBecomesPersonal() throws {
        var old = AppSettings()
        old.mode = .hybrid
        old.autoEnabled = false
        try store.saveSettings(old)
        try boot(at: 9)
        XCTAssertEqual(engine.settings.mode, .automatic)
        XCTAssertTrue(engine.settings.autoEnabled)
        XCTAssertEqual(engine.status, .personal)
    }

    // MARK: The stretch since the last break

    func testEndWorkStartsANewStretchAlsoWhenNothingElseChanges() throws {
        // Slack is non-work in both profiles, so the recorded interval does not change on End work.
        engine.appActivated(slack)
        let first = try XCTUnwrap(engine.sessionStart)
        time.advance(600)
        engine.endWork()
        XCTAssertEqual(engine.sessionStart, time.now)
        XCTAssertNotEqual(engine.sessionStart, first)
        time.advance(60)
        engine.startWork()
        XCTAssertEqual(engine.sessionStart, time.now)
    }

    func testStartWorkWithEvidenceKeepsTheStretch() throws {
        engine.endWork()
        engine.appActivated(xcode)
        let start = try XCTUnwrap(engine.sessionStart)
        time.advance(720)
        engine.startWork(includeEvidence: true)
        XCTAssertEqual(engine.sessionStart, start, "the evidence was work without a break")
    }

    // MARK: Evidence ("Is this work?")

    func testEvidenceIsMovedToWorkOnRequest() throws {
        engine.endWork()
        engine.appActivated(xcode)
        time.advance(400)
        engine.appActivated(slack)   // a short look at another application keeps the evidence
        time.advance(60)
        engine.appActivated(xcode)
        time.advance(320)
        XCTAssertEqual(engine.evidenceSeconds, 720, accuracy: 0.001)
        XCTAssertEqual(engine.evidenceApp, "Xcode")

        engine.startWork(includeEvidence: true)
        XCTAssertEqual(engine.evidenceSeconds, 0)
        time.advance(300)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(total(sessions, .work), 1020, accuracy: 0.001)     // 720 moved + 300 new
        XCTAssertEqual(total(sessions, .nonwork), 60, accuracy: 0.001)    // Slack stays non-work
        assertNoOverlap(sessions)
    }

    func testEvidenceEndsWhenTheUserIsAway() throws {
        engine.endWork()
        engine.appActivated(xcode)
        time.advance(200)
        XCTAssertEqual(engine.evidenceSeconds, 200, accuracy: 0.001)
        time.advance(400)
        engine.tick(idleSeconds: 400)        // idle threshold is 300 s
        XCTAssertEqual(engine.evidenceSeconds, 0)
    }

    func testNoEvidenceForNonWorkApplications() throws {
        engine.endWork()
        engine.appActivated(slack)
        time.advance(900)
        XCTAssertEqual(engine.evidenceSeconds, 0)
    }

    func testMarkAsWorkOnlyTouchesNonWork() throws {
        let idle = try store.insert(makeSession(monday, 9, 10, kind: .idle))
        let other = try store.insert(makeSession(monday, 10, 11, kind: .nonwork))
        try store.markAsWork([idle, other])
        XCTAssertEqual(try all().map(\.kind), [.idle, .work])
    }

    // MARK: Work hours

    func testStartOfWorkHoursTurnsWorkOn() throws {
        try boot(at: 7.5)
        engine.endWork()
        useWorkHours()
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.status, .personal, "before work hours nothing changes")

        time.advance(31 * 60)                // 08.01
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .work)
        XCTAssertFalse(engine.isOvertime)
    }

    func testChoiceBetweenBoundariesIsKeptUntilTheNextStart() throws {
        useWorkHours()
        engine.tick(idleSeconds: 0)          // 09.00 on a work day: inside work hours
        XCTAssertEqual(engine.settings.profile, .work)

        engine.endWork()                     // the user chooses Personal at 09.00
        time.advance(3 * 3600)
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .personal)

        time.advance(20 * 3600 + 60)         // Tuesday 08.01
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .work)
    }

    func testStillWorkingAtTheEndIsOvertime() throws {
        try boot(at: 15.9)
        useWorkHours()
        engine.appActivated(xcode)
        engine.tick(idleSeconds: 0)
        time.advance(10 * 60)                // 16.04
        engine.tick(idleSeconds: 5)
        XCTAssertEqual(hoursEnded, 1)
        XCTAssertEqual(engine.settings.profile, .work)
        XCTAssertTrue(engine.isOvertime)

        time.advance(60)
        engine.tick(idleSeconds: 5)
        XCTAssertEqual(hoursEnded, 1, "the end of work hours is announced once")

        time.advance(16 * 60)                // no input for 16 minutes (limit is 15)
        engine.tick(idleSeconds: 16 * 60)
        XCTAssertEqual(engine.settings.profile, .personal)
        XCTAssertFalse(engine.isOvertime)
    }

    func testAwayAtTheEndGoesToPersonalQuietly() throws {
        try boot(at: 15.8)
        useWorkHours()
        engine.appActivated(xcode)
        engine.tick(idleSeconds: 0)
        time.advance(13 * 60)                // 16.01, no input for 13 minutes
        engine.tick(idleSeconds: 13 * 60)
        XCTAssertEqual(hoursEnded, 0)
        XCTAssertEqual(engine.settings.profile, .personal)
    }

    func testScreenLockEndsOvertime() throws {
        try boot(at: 15.9)
        useWorkHours()
        engine.appActivated(xcode)
        engine.tick(idleSeconds: 0)
        time.advance(10 * 60)
        engine.tick(idleSeconds: 0)
        XCTAssertTrue(engine.isOvertime)
        engine.screenLocked()
        XCTAssertEqual(engine.settings.profile, .personal)
    }

    func testWorkingAgentKeepsOvertimeOn() throws {
        try boot(at: 15.9)
        useWorkHours()
        engine.appActivated(slack)
        engine.setAgent("Claude Code")
        engine.tick(idleSeconds: 0)
        time.advance(10 * 60)                // 16.04, the user left 10 minutes ago
        engine.tick(idleSeconds: 10 * 60)
        XCTAssertEqual(hoursEnded, 1)
        XCTAssertEqual(engine.settings.profile, .work)

        time.advance(20 * 60)
        engine.tick(idleSeconds: 30 * 60)
        XCTAssertEqual(engine.settings.profile, .work, "the agent still works")

        engine.setAgent(nil)
        engine.tick(idleSeconds: 30 * 60)
        XCTAssertEqual(engine.settings.profile, .personal)
    }

    func testEndMissedWhileTheAppWasClosed() throws {
        useWorkHours()
        engine.tick(idleSeconds: 0)
        engine.shutdown()
        try boot(at: 20)                     // relaunched four hours after the end
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(hoursEnded, 0)
        XCTAssertEqual(engine.settings.profile, .personal)
    }

    func testOvertimeStartedByHandOutsideWorkHours() throws {
        try boot(at: 19)
        engine.endWork()
        useWorkHours()
        engine.tick(idleSeconds: 0)
        engine.startWork()
        engine.appActivated(xcode)
        time.advance(600)
        engine.tick(idleSeconds: 0)
        XCTAssertTrue(engine.isOvertime)
        XCTAssertEqual(engine.status, .tracking(.work))
    }

    func testNoWorkHoursMeansNoAutomaticChange() throws {
        engine.endWork()
        time.advance(24 * 3600)
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .personal)
        XCTAssertFalse(engine.isOvertime)
    }

    // MARK: Schedule arithmetic

    private func local(_ day: LocalDay, _ hour: Double) -> Double { Double(day.index) * 86400 + hour * 3600 }

    func testScheduleWindows() {
        let s = WorkSchedule(enabled: true, days: weekdays, startMinutes: 480, endMinutes: 960)
        XCTAssertTrue(s.contains(local: local(monday, 8)))
        XCTAssertTrue(s.contains(local: local(monday, 15.99)))
        XCTAssertFalse(s.contains(local: local(monday, 16)))
        XCTAssertFalse(s.contains(local: local(monday.adding(5), 10)), "Saturday")
        XCTAssertEqual(s.lengthMinutes, 480)
        XCTAssertEqual(s.lastStart(atOrBefore: local(monday, 7)), local(monday.adding(-3), 8), "Friday")
        XCTAssertEqual(s.lastEnd(atOrBefore: local(monday, 17)), local(monday, 16))
        XCTAssertEqual(s.nextStart(after: local(monday.adding(4), 9)), local(monday.adding(7), 8), "Friday to Monday")
        XCTAssertEqual(s.currentEnd(local: local(monday, 9)), local(monday, 16))
        XCTAssertNil(s.currentEnd(local: local(monday, 17)))
    }

    func testScheduleAcrossMidnight() {
        let s = WorkSchedule(enabled: true, days: [2], startMinutes: 22 * 60, endMinutes: 6 * 60)   // Monday night
        XCTAssertEqual(s.lengthMinutes, 480)
        XCTAssertTrue(s.contains(local: local(monday, 23)))
        XCTAssertTrue(s.contains(local: local(monday.adding(1), 5)), "Tuesday morning belongs to Monday's hours")
        XCTAssertFalse(s.contains(local: local(monday.adding(1), 7)))
        XCTAssertEqual(s.overlap(localFrom: local(monday, 21), to: local(monday.adding(1), 7)), 8 * 3600)
    }

    func testUnusableSchedules() {
        XCTAssertFalse(WorkSchedule().isUsable, "off by default")
        XCTAssertFalse(WorkSchedule(enabled: true, days: [], startMinutes: 480, endMinutes: 960).isUsable)
        XCTAssertFalse(WorkSchedule(enabled: true, days: weekdays, startMinutes: 480, endMinutes: 480).isUsable)
        XCTAssertFalse(WorkSchedule(enabled: true, days: weekdays, startMinutes: 480, endMinutes: 480).contains(local: local(monday, 9)))
    }

    func testOvertimeIsWorkOutsideWorkHours() {
        let s = WorkSchedule(enabled: true, days: weekdays, startMinutes: 480, endMinutes: 960)
        let saturday = monday.adding(5)
        let sessions = [makeSession(monday, 15, 17), makeSession(monday, 18, 19, kind: .nonwork), makeSession(saturday, 10, 11)]
        XCTAssertEqual(Aggregator.overtime(sessions, on: monday, schedule: s), 3600)
        XCTAssertEqual(Aggregator.overtime(sessions, on: saturday, schedule: s), 3600)
        XCTAssertEqual(Aggregator.overtime(sessions, on: monday, schedule: WorkSchedule()), 0, "no work hours, no overtime")
    }

    // MARK: Derived goals

    func testWeekAndMonthGoalsComeFromTheDailyGoal() {
        let h = 3600.0
        let config = GoalConfig(effectiveFrom: monday, dailyHours: 6, workingDays: weekdays)
        func evaluate(_ period: Period, _ configs: [GoalConfig]) -> PeriodResult {
            Goals.evaluate(period, containing: monday, totals: [:], configs: configs, today: monday, firstWeekday: 2)
        }
        XCTAssertEqual(evaluate(.week, [config]).targetSeconds, 30 * h)
        XCTAssertEqual(evaluate(.month, [config]).targetSeconds, 126 * h, "March 2024 has 21 work days")

        let own = GoalConfig(effectiveFrom: monday, dailyHours: 6, weeklyHours: 20, monthlyHours: 80, workingDays: weekdays)
        XCTAssertEqual(evaluate(.week, [own]).targetSeconds, 20 * h, "a goal that was set by hand is kept")
        XCTAssertEqual(evaluate(.month, [own]).targetSeconds, 80 * h)
        XCTAssertNil(evaluate(.week, [GoalConfig(effectiveFrom: monday)]).targetSeconds)
    }

    // MARK: Days off

    func testWorkHoursStartIsAnnouncedOnce() throws {
        try boot(at: 7.5)
        useWorkHours()
        engine.tick(idleSeconds: 0)
        time.advance(31 * 60)                // 08.01
        engine.tick(idleSeconds: 0)
        time.advance(60)
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(hoursStarted, 1)

        engine.endWork()
        time.advance(24 * 3600)              // Tuesday 08.02: Personal changes to Work, announced again
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(hoursStarted, 2)
    }

    func testNoWorkHoursOnADayOff() throws {
        try boot(at: 7.5)
        engine.endWork()
        useWorkHours()
        engine.updateSettings { $0.schedule.daysOff = [DayOff(from: monday.index, to: monday.index, name: "Holiday")] }
        time.advance(3600)                   // Monday 08.30
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .personal)
        XCTAssertEqual(hoursStarted, 0)
        XCTAssertFalse(engine.inWorkHours)
        XCTAssertTrue(engine.isDayOffToday)

        time.advance(24 * 3600)              // Tuesday 08.30
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .work)
        XCTAssertEqual(hoursStarted, 1)
    }

    func testTodayIsADayOffMovesTodaysWorkAndCanBeUndone() throws {
        try boot(at: 7.95)
        useWorkHours()
        engine.appActivated(xcode)
        engine.tick(idleSeconds: 0)
        time.advance(4 * 60)                 // 08.01: work hours start
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .work)
        time.advance(2 * 3600)               // 10.01
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(total(try all(), .work), 2 * 3600, accuracy: 1)

        engine.takeDayOff(moveWork: true)
        XCTAssertEqual(total(try all(), .work), 0, "today's work is now non-work")
        XCTAssertEqual(engine.settings.profile, .personal)
        XCTAssertTrue(engine.isDayOffToday)
        XCTAssertFalse(engine.isOvertime)
        XCTAssertEqual(engine.settings.dayOffUndo?.movedSeconds ?? 0, 2 * 3600, accuracy: 1)

        time.advance(600)                    // 10.11: no automatic start on a day off
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.settings.profile, .personal)

        engine.undoDayOff()
        XCTAssertEqual(total(try all(), .work), 2 * 3600, accuracy: 1, "the moved time is work again")
        XCTAssertEqual(engine.settings.profile, .work)
        XCTAssertFalse(engine.isDayOffToday)
        XCTAssertNil(engine.settings.dayOffUndo)
        engine.shutdown()
        assertNoOverlap(try all())
    }

    func testKeepingTheWorkAndWorkingOnADayOffIsOvertime() throws {
        useWorkHours()
        engine.appActivated(xcode)
        engine.tick(idleSeconds: 0)          // Monday 09.00, Work
        time.advance(600)
        engine.tick(idleSeconds: 0)
        engine.takeDayOff(moveWork: false)
        XCTAssertEqual(total(try all(), .work), 600, accuracy: 1, "the work stays")
        engine.startWork()
        XCTAssertTrue(engine.isOvertime)
        time.advance(1200)
        engine.shutdown()
        XCTAssertEqual(Aggregator.overtime(try all(), on: monday, schedule: engine.settings.schedule), 1800, accuracy: 1,
                       "all work on a day off is overtime")
    }

    func testUndoEndsWhenTheNextWorkHoursStart() throws {
        useWorkHours()
        engine.tick(idleSeconds: 0)
        engine.takeDayOff(moveWork: true)
        XCTAssertNotNil(engine.settings.dayOffUndo)
        time.advance(23 * 3600 + 60)         // Tuesday 08.01
        engine.tick(idleSeconds: 0)
        XCTAssertNil(engine.settings.dayOffUndo)
        XCTAssertEqual(engine.settings.profile, .work)
    }

    func testDaysOffLowerTheGoals() {
        let config = GoalConfig(effectiveFrom: monday, dailyHours: 6, workingDays: weekdays)
        func evaluate(_ period: Period) -> PeriodResult {
            Goals.evaluate(period, containing: monday, totals: [:], configs: [config], today: monday, firstWeekday: 2,
                           isDayOff: { $0 == monday })
        }
        XCTAssertNil(evaluate(.day).targetSeconds, "no daily goal on a day off")
        XCTAssertEqual(evaluate(.week).targetSeconds, 24 * 3600)
        XCTAssertEqual(evaluate(.month).targetSeconds, 120 * 3600)
    }

    func testDayOffRanges() {
        let leave = DayOff(from: 12, to: 10)
        XCTAssertEqual(leave.from, 10, "a range is stored in order")
        XCTAssertEqual(leave.count, 3)
        XCTAssertTrue(leave.overlaps(DayOff(from: 12, to: 14)))
        XCTAssertFalse(leave.overlaps(DayOff(from: 13, to: 14)))
    }
}
