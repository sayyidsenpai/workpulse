import XCTest
@testable import WorkPulseCore

/// Whole days as a user lives them, from the morning to the next day.
/// Each step checks the status, the profile, the work session ("This session"), and what was recorded.
final class DayLifecycleTests: XCTestCase {
    typealias App = TrackingEngine.FrontApp

    var store: Store!
    var time: FakeTime!
    var engine: TrackingEngine!
    var hoursEnded = 0
    var hoursStarted = 0
    let xcode = App(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    let music = App(bundleID: "com.apple.Music", name: "Music")
    let tuesday = LocalDay(index: monday.index + 1)
    let saturday = LocalDay(index: monday.index + 5)

    override func setUpWithError() throws {
        store = try Store()
        try store.saveRule(AppRule(bundleID: xcode.bundleID, appName: xcode.name, categoryID: Store.workID))
        try store.saveRule(AppRule(bundleID: music.bundleID, appName: music.name, categoryID: Store.ignoredID))
    }

    /// A fresh engine on the same store, as after a launch (or a relaunch after a crash).
    private func boot(_ day: LocalDay, _ hour: Double) { boot(at(day, hour)) }

    private func boot(_ date: Date) {
        time = FakeTime(date)
        engine = TrackingEngine(store: store, time: time)
        engine.recover()
        engine.onWorkHoursEnded = { [unowned self] in hoursEnded += 1 }
        engine.onWorkHoursStarted = { [unowned self] in hoursStarted += 1 }
    }

    private func useWorkHours() {
        engine.updateSettings { $0.schedule = WorkSchedule(enabled: true, days: [2, 3, 4, 5, 6], startMinutes: 8 * 60, endMinutes: 16 * 60) }
    }

    /// Moves time on with the user active (input `idle` seconds ago) and lets the engine see it.
    private func pass(_ seconds: TimeInterval, idle: TimeInterval = 0) {
        time.advance(seconds)
        engine.tick(idleSeconds: idle)
    }

    private func sessions(on day: LocalDay) throws -> [Session] { try store.sessions(days: day...day) }

    func testOneWorkDayFromMorningToOvertime() throws {
        boot(monday, 7.5)
        engine.endWork()
        useWorkHours()

        // 07.30 Personal: a work app is used before work hours. Nothing counts as work.
        engine.appActivated(xcode)
        pass(12 * 60)
        XCTAssertEqual(engine.status, .personal)
        XCTAssertEqual(engine.evidenceSeconds, 720, accuracy: 0.5, "the 'Is this work?' evidence grows")
        XCTAssertEqual(total(try sessions(on: monday), .work), 0)

        // 08.01 Work hours start: Work profile, one notice, a new work session.
        pass(19 * 60)
        XCTAssertEqual(engine.settings.profile, .work)
        XCTAssertEqual(hoursStarted, 1)
        XCTAssertEqual(engine.status, .tracking(.work))
        let session = try XCTUnwrap(engine.workSessionStart)
        XCTAssertEqual(session, at(monday, 8), "the session starts at the start of the work hours")

        // Other applications: the session goes on; an ignored app keeps no identity.
        pass(2 * 3600)
        engine.appActivated(slack)
        XCTAssertEqual(engine.status, .tracking(.nonwork))
        pass(10 * 60)
        engine.appActivated(music)
        XCTAssertEqual(engine.status, .tracking(.excluded))
        pass(5 * 60)
        engine.appActivated(xcode)
        XCTAssertEqual(engine.workSessionStart, session, "changing applications does not end the session")

        // Idle: trimmed back to the last input; the session goes on.
        time.advance(400)
        engine.tick(idleSeconds: 300)
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(engine.idleSince, time.now.addingTimeInterval(-300))
        pass(100, idle: 2)
        XCTAssertEqual(engine.status, .tracking(.work))
        XCTAssertEqual(engine.workSessionStart, session)

        // Lock and sleep inside work hours: away, but still the Work profile.
        engine.screenLocked()
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(engine.settings.profile, .work)
        time.advance(120)
        engine.screenUnlocked()
        XCTAssertEqual(engine.status, .tracking(.work))
        engine.willSleep()
        XCTAssertEqual(engine.status, .idle)
        time.advance(600)
        engine.didWake()
        pass(60)
        XCTAssertEqual(engine.status, .tracking(.work))

        // A lunch break: the user walks away. Idle, not work; the session goes on.
        time.advance(at(monday, 12).timeIntervalSince(time.now))
        engine.tick(idleSeconds: 0)
        let awayFrom = time.now
        time.advance(30 * 60)
        engine.tick(idleSeconds: 30 * 60)
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(engine.settings.profile, .work, "inside work hours being away keeps the Work profile")
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.status, .tracking(.work))
        XCTAssertEqual(engine.workSessionStart, session, "a break does not end the session")
        let backAt = time.now

        // An agent works while the user is in a non-work app and then idle: that counts as work.
        engine.appActivated(slack)
        engine.setAgent("Claude Code")
        XCTAssertEqual(engine.status, .tracking(.work))
        time.advance(600)
        engine.tick(idleSeconds: 400)
        XCTAssertEqual(engine.status, .tracking(.work), "the agent keeps recording work while the user is idle")
        engine.setAgent(nil)
        engine.appActivated(xcode)
        pass(60)

        // 16.04 Work hours end while working: overtime, announced once.
        time.advance(at(monday, 16.0 + 4.0 / 60).timeIntervalSince(time.now))
        engine.tick(idleSeconds: 5)
        XCTAssertTrue(engine.isOvertime)
        XCTAssertEqual(hoursEnded, 1)
        pass(30 * 60)                                            // 16.34
        engine.checkpoint()
        let overtime = Aggregator.overtime(try sessions(on: monday), on: monday, schedule: engine.settings.schedule)
        XCTAssertEqual(overtime, 34 * 60, accuracy: 1, "all work after 16.00 is overtime")

        // End work ends the session; Start overtime starts a new one.
        engine.endWork()
        XCTAssertEqual(engine.status, .personal)
        XCTAssertNil(engine.workSessionStart)
        pass(5 * 60)
        engine.startWork()
        XCTAssertEqual(engine.status, .tracking(.work))
        XCTAssertTrue(engine.isOvertime)
        XCTAssertEqual(engine.workSessionStart, time.now)

        // Away for 16 minutes in overtime: back to Personal by itself.
        time.advance(16 * 60)
        engine.tick(idleSeconds: 16 * 60)
        XCTAssertEqual(engine.settings.profile, .personal)
        engine.shutdown()

        let day = try sessions(on: monday)
        assertNoOverlap(day)
        XCTAssertEqual(Aggregator.work(day, since: session), total(day, .work), accuracy: 0.001,
                       "the first session holds all of the day's work")
        XCTAssertFalse(day.contains { $0.kind == .work && $0.start < backAt && $0.end > awayFrom }, "no work is recorded during the break")
        XCTAssertTrue(day.filter { $0.kind == .excluded }.allSatisfy { $0.appName == nil && $0.bundleID == nil })
        XCTAssertGreaterThan(day.filter { $0.source == .agent && $0.kind == .work }.reduce(0) { $0 + $1.duration }, 0)
        XCTAssertEqual(day.filter { $0.end <= at(monday, 8) }.filter { $0.kind == .work }.count, 0, "nothing before work hours is work")
    }

    func testDayOffUndoCrashAndWeekendOvertime() throws {
        // Tuesday 08.30: working, then the user takes the day off and changes their mind.
        boot(tuesday, 8.5)
        useWorkHours()
        engine.appActivated(xcode)
        pass(0)
        XCTAssertEqual(engine.settings.profile, .work)
        pass(30 * 60)
        engine.takeDayOff(moveWork: true)
        XCTAssertEqual(engine.status, .personal)
        XCTAssertTrue(engine.isDayOffToday)
        XCTAssertEqual(total(try sessions(on: tuesday), .work), 0, "today's work moves to non-work")
        engine.undoDayOff()
        XCTAssertEqual(engine.settings.profile, .work)
        XCTAssertFalse(engine.isDayOffToday)
        XCTAssertEqual(total(try sessions(on: tuesday), .work), 30 * 60, accuracy: 1, "undo gives the work back")
        XCTAssertEqual(engine.workSessionStart, time.now)

        // A crash in the middle of a session (no shutdown), then a relaunch 20 minutes later.
        pass(10 * 60)
        engine.checkpoint()
        let lastCheckpoint = time.now
        boot(lastCheckpoint.addingTimeInterval(20 * 60))
        let relaunch = time.now
        engine.appActivated(xcode)
        pass(5 * 60)
        engine.shutdown()
        let afterCrash = try sessions(on: tuesday)
        assertNoOverlap(afterCrash)
        XCTAssertTrue(afterCrash.allSatisfy { $0.end.timeIntervalSince(time.now) < 0.001 }, "no session reaches into the future")
        XCTAssertEqual(afterCrash.map(\.endReason), ["dayoff", "recovered", "quit"], "the open session is closed at its last checkpoint")
        XCTAssertFalse(afterCrash.contains { $0.start < relaunch.addingTimeInterval(-60) && $0.end > relaunch },
                       "the time the app was not running is not counted")

        // Saturday: no work hours. Work started by hand is all overtime.
        boot(saturday, 10)
        engine.endWork()
        useWorkHours()
        pass(0)                       // the app polls at launch, before the user can press a button
        engine.startWork()
        engine.appActivated(xcode)
        pass(3600)
        XCTAssertTrue(engine.isOvertime)
        engine.checkpoint()
        XCTAssertEqual(Aggregator.overtime(try sessions(on: saturday), on: saturday, schedule: engine.settings.schedule),
                       3600, accuracy: 1)
        engine.shutdown()
    }

    // MARK: Edge cases of the work session

    func testWorkHoursPastMidnightKeepOneSessionPerWorkDay() throws {
        // 07.40 to 00.15, like a late schedule: the work day ends after midnight.
        boot(monday, 7.5)
        engine.endWork()
        engine.updateSettings { $0.schedule = WorkSchedule(enabled: true, days: [2, 3, 4, 5, 6], startMinutes: 7 * 60 + 40, endMinutes: 15) }
        engine.appActivated(xcode)
        pass(11 * 60)                                            // 07.41
        XCTAssertEqual(engine.settings.profile, .work)
        let session = try XCTUnwrap(engine.workSessionStart)
        XCTAssertEqual(session, at(monday, 7 + 40.0 / 60))

        time.advance(at(tuesday, 0 + 10.0 / 60).timeIntervalSince(time.now))   // Tuesday 00.10, still Monday's work hours
        engine.tick(idleSeconds: 0)
        XCTAssertFalse(engine.isOvertime)
        XCTAssertEqual(engine.workSessionStart, session, "midnight does not start a new session")

        pass(6 * 60)                                             // 00.16: Monday's work hours ended a minute ago
        XCTAssertTrue(engine.isOvertime)
        XCTAssertEqual(engine.workSessionStart, session)

        time.advance(at(tuesday, 7 + 41.0 / 60).timeIntervalSince(time.now))   // still working at Tuesday 07.41
        engine.tick(idleSeconds: 0)
        XCTAssertEqual(engine.workSessionStart, at(tuesday, 7 + 40.0 / 60), "the next work day starts a new session")
        engine.shutdown()
        assertNoOverlap(try store.sessions())
    }

    func testClockAndTimeZoneChangesKeepTheSessionHonest() throws {
        boot(monday, 9)
        engine.appActivated(xcode)
        pass(0)
        let session = try XCTUnwrap(engine.workSessionStart)
        pass(3600)

        time.now -= 2 * 3600                                     // the clock is set back two hours
        engine.clockChanged()
        pass(1800)
        time.now += 3 * 3600                                     // then three hours forward
        engine.clockChanged()
        pass(1800)
        time.tzOffset = 3600                                     // a new time zone
        pass(1800)
        engine.shutdown()

        let all = try store.sessions()
        assertNoOverlap(all)
        XCTAssertEqual(engine.workSessionStart, session, "clock and zone changes do not end the session")
        XCTAssertEqual(Aggregator.work(all, since: session), 3600 + 3 * 1800, accuracy: 1,
                       "only the time actually worked counts, not the clock jumps")
    }

    func testASessionWithoutWorkHoursCanLastDays() throws {
        boot(monday, 9)                                          // no work hours: Work stays on until End work
        engine.appActivated(xcode)
        pass(0)
        let session = try XCTUnwrap(engine.workSessionStart)
        pass(3600)
        engine.shutdown()
        boot(LocalDay(index: monday.index + 8), 9)               // the Tuesday of the next week
        engine.appActivated(xcode)
        pass(1800)
        engine.shutdown()
        XCTAssertEqual(engine.workSessionStart, session)
        XCTAssertEqual(Aggregator.work(try store.sessions(from: session), since: session), 5400, accuracy: 1,
                       "all of the session's work counts, also from an earlier week")
    }
}
