import XCTest
@testable import WorkPulseCore

final class EngineTests: XCTestCase {
    typealias App = TrackingEngine.FrontApp

    var store: Store!
    var time: FakeTime!
    var engine: TrackingEngine!
    let xcode = App(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    let safari = App(bundleID: "com.apple.Safari", name: "Safari")

    override func setUpWithError() throws {
        store = try Store()
        try store.saveRule(AppRule(bundleID: xcode.bundleID, appName: xcode.name, categoryID: Store.workID))
        time = FakeTime(at(monday, 9))
        engine = TrackingEngine(store: store, time: time)
        engine.recover()
    }

    private func all() throws -> [Session] { try store.sessions() }

    // MARK: Automatic tracking and classification

    func testAutomaticModeClassifiesByApplicationRule() throws {
        engine.appActivated(xcode)
        time.advance(600)
        engine.appActivated(slack)
        time.advance(300)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map(\.kind), [.work, .nonwork])
        XCTAssertEqual(sessions.map(\.appName), ["Xcode", "Slack"])
        XCTAssertEqual(sessions[0].duration, 600, accuracy: 0.001)
        XCTAssertEqual(sessions[1].duration, 300, accuracy: 0.001)
        XCTAssertEqual(sessions[0].categoryID, Store.workID)
        XCTAssertEqual(sessions[1].categoryID, Store.uncategorizedID)
        XCTAssertEqual(sessions[0].endReason, "switch")
        XCTAssertEqual(sessions[1].endReason, "quit")
        assertNoOverlap(sessions)
    }

    func testDuplicateEventsDoNotCreateSessions() throws {
        engine.appActivated(xcode)
        time.advance(100)
        engine.appActivated(xcode)
        engine.tick(idleSeconds: 0)
        engine.tick(idleSeconds: 0)
        engine.screenUnlocked()  // was never locked
        engine.didWake()         // was never asleep
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].duration, 200, accuracy: 0.001)
    }

    func testBrowserIsNeverWorkJustBecauseItIsActive() throws {
        engine.updateSettings { $0.unclassifiedIsWork = true }
        engine.appActivated(slack)
        time.advance(100)
        engine.appActivated(safari)
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map(\.kind), [.work, .nonwork], "unclassified apps may default to work, browsers may not")
        // An explicit rule is the only way a browser counts as work.
        try store.saveRule(AppRule(bundleID: safari.bundleID, appName: "Safari", categoryID: Store.workID))
        engine.reloadRules()
        engine.appActivated(safari)
        time.advance(50)
        engine.shutdown()
        XCTAssertEqual(try all().last?.kind, .work)
    }

    func testIgnoredApplicationLeavesNoIdentity() throws {
        try store.saveRule(AppRule(bundleID: slack.bundleID, appName: slack.name, categoryID: Store.ignoredID))
        engine.reloadRules()
        engine.appActivated(slack)
        time.advance(100)
        engine.shutdown()

        let session = try XCTUnwrap(try all().first)
        XCTAssertEqual(session.kind, .excluded)
        XCTAssertNil(session.bundleID)
        XCTAssertNil(session.appName)
    }

    func testSubSecondIntervalsAreDroppedNotInvented() throws {
        engine.appActivated(xcode)
        time.advance(100)
        engine.appActivated(slack)
        time.advance(0.5)
        engine.appActivated(xcode)
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map(\.appName), ["Xcode", "Xcode"])
        XCTAssertEqual(total(sessions, .work), 200, accuracy: 0.001)
        assertNoOverlap(sessions)
    }

    func testRuleChangeDuringActiveSessionAppliesFromNowOn() throws {
        engine.appActivated(slack)
        time.advance(100)
        try store.saveRule(AppRule(bundleID: slack.bundleID, appName: slack.name, categoryID: Store.workID))
        engine.reloadRules()
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map(\.kind), [.nonwork, .work])
        XCTAssertEqual(sessions[0].duration, 100, accuracy: 0.001, "time before the change keeps its old classification")
        XCTAssertEqual(sessions[0].endReason, "rules")
        assertNoOverlap(sessions)
    }

    func testActiveProjectIsRecordedOnWorkOnly() throws {
        try store.saveProject(Project(name: "Client A"))
        let project = try XCTUnwrap(try store.projects().first)
        engine.updateSettings { $0.activeProjectID = project.id }
        engine.appActivated(xcode)
        time.advance(100)
        engine.appActivated(slack)
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions[0].projectID, project.id)
        XCTAssertNil(sessions[1].projectID)
    }

    // MARK: Idle detection and automatic pause/resume

    func testIdleTrimsBackToLastInputAndResumesOnActivity() throws {
        engine.appActivated(xcode)
        time.advance(400)                    // last input was 300 s ago
        engine.tick(idleSeconds: 300)        // threshold (300 s) reached
        XCTAssertEqual(engine.status, .idle)

        time.advance(500)
        engine.tick(idleSeconds: 2)          // user came back 2 s ago
        XCTAssertEqual(engine.status, .tracking(.work))
        time.advance(102)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map(\.kind), [.work, .idle, .work])
        XCTAssertEqual(sessions[0].duration, 100, accuracy: 0.001, "work stops at the last input, not at detection")
        XCTAssertEqual(sessions[0].endReason, "idle")
        XCTAssertEqual(sessions[1].duration, 798, accuracy: 0.001)
        XCTAssertEqual(sessions[2].duration, 104, accuracy: 0.001)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.duration }, 1002, accuracy: 0.001, "every second is accounted for exactly once")
        assertNoOverlap(sessions)
    }

    func testIdleBelowThresholdKeepsTracking() throws {
        engine.appActivated(xcode)
        time.advance(200)
        engine.tick(idleSeconds: 199)
        XCTAssertEqual(engine.status, .tracking(.work))
        XCTAssertEqual(try all().count, 1)
    }

    func testIdleBeforeLaunchIsNotBackdated() throws {
        // The Mac sat unused for an hour before WorkPulse started recording.
        engine.appActivated(xcode)
        time.advance(5)
        engine.tick(idleSeconds: 3600)
        time.advance(60)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].kind, .idle)
        XCTAssertGreaterThanOrEqual(sessions[0].start, at(monday, 9), "nothing may be recorded before tracking began")
    }

    func testPerApplicationIdleRule() throws {
        try store.saveRule(AppRule(bundleID: xcode.bundleID, appName: xcode.name, categoryID: Store.workID, idleThreshold: 0))
        engine.reloadRules()
        engine.appActivated(xcode)
        time.advance(4000)
        engine.tick(idleSeconds: 4000)
        XCTAssertEqual(engine.status, .tracking(.work), "threshold 0 means this app is never treated as idle")
        XCTAssertEqual(engine.nextCheckDelay(idleSeconds: 4000), TrackingEngine.checkpointInterval)
    }

    func testNextCheckIsScheduledAtTheIdleThreshold() {
        engine.appActivated(xcode)
        XCTAssertEqual(engine.nextCheckDelay(idleSeconds: 0), 30)
        XCTAssertEqual(engine.nextCheckDelay(idleSeconds: 290), 10)
        XCTAssertEqual(engine.nextCheckDelay(idleSeconds: 299.8), 1)
        engine.tick(idleSeconds: 300)
        XCTAssertEqual(engine.nextCheckDelay(idleSeconds: 300), 3, "poll quickly for the user's return while idle")
    }

    // MARK: Lock, sleep, clock

    func testScreenLockAndSleepAreNotWork() throws {
        engine.appActivated(xcode)
        time.advance(100)
        engine.screenLocked()
        engine.screenLocked()
        time.advance(300)
        engine.screenUnlocked()
        time.advance(100)
        engine.willSleep()
        time.now += 3600                     // asleep: wall clock moves, uptime does not
        engine.didWake()
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(total(sessions, .work), 300, accuracy: 0.001)
        XCTAssertEqual(total(sessions, .idle), 300, accuracy: 0.001)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.duration }, 600, accuracy: 0.001, "the hour asleep is not on the timeline at all")
        XCTAssertEqual(sessions.map(\.endReason), ["lock", "activity", "sleep", "quit"])
        assertNoOverlap(sessions)
    }

    func testUnnoticedSleepDoesNotFabricateTime() throws {
        engine.appActivated(xcode)
        time.advance(100)
        time.now += 3600                     // slept without any notification reaching us
        engine.tick(idleSeconds: 0)
        time.advance(50)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(total(sessions, .work), 150, accuracy: 0.001)
        XCTAssertEqual(sessions[1].start.timeIntervalSince(sessions[0].start), 3700, accuracy: 0.001)
        assertNoOverlap(sessions)
    }

    func testClockSetBackwardsNeverOverlapsOrChangesDurations() throws {
        engine.appActivated(xcode)
        time.advance(600)
        time.now -= 3600
        engine.clockChanged()
        XCTAssertTrue(engine.clockBehind)
        time.advance(300)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map { $0.duration.rounded() }, [600, 300])
        assertNoOverlap(sessions)
    }

    func testClockSetForwardKeepsDuration() throws {
        engine.appActivated(xcode)
        time.advance(600)
        time.now += 7200
        engine.clockChanged()
        time.advance(60)
        engine.shutdown()

        XCTAssertEqual(total(try all(), .work), 660, accuracy: 0.001)
    }

    func testTimeZoneChangeStartsNewSessionWithNewOffset() throws {
        engine.appActivated(xcode)
        time.advance(100)
        time.tzOffset = 3600
        engine.tick(idleSeconds: 0)
        time.advance(100)
        engine.shutdown()

        XCTAssertEqual(try all().map(\.tzOffset), [0, 3600])
    }

    // MARK: Modes and controls

    func testStopStart() throws {
        engine.appActivated(xcode)
        time.advance(100)
        engine.stop()
        XCTAssertEqual(engine.status, .stopped)
        XCTAssertFalse(try store.loadSettings().autoEnabled, "Stop is remembered across restarts")
        time.advance(100)
        engine.start()
        time.advance(10)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map { $0.duration.rounded() }, [100, 10])
        XCTAssertEqual(sessions.map(\.endReason), ["stop", "quit"])
    }

    func testWorkSinceCountsOnlyWorkFromTheStart() {
        let sessions = [makeSession(monday, 8, 10), makeSession(monday, 10, 11, kind: .nonwork), makeSession(monday, 11, 12)]
        XCTAssertEqual(Aggregator.work(sessions, since: at(monday, 9)), 2 * 3600, accuracy: 0.001)
        XCTAssertEqual(Aggregator.work(sessions, since: at(monday, 13)), 0)
    }

    func testHeadlineSaysOneThingInAFixedOrder() {
        XCTAssertEqual(Headline(status: .tracking(.work), overtime: true, agent: true, dayOff: false), .overtime)
        XCTAssertEqual(Headline(status: .tracking(.work), overtime: false, agent: true, dayOff: false), .agent)
        XCTAssertEqual(Headline(status: .tracking(.work), overtime: false, agent: false, dayOff: false), .tracking)
        XCTAssertEqual(Headline(status: .tracking(.idle), overtime: true, agent: false, dayOff: false), .idle)
        XCTAssertEqual(Headline(status: .personal, overtime: false, agent: false, dayOff: true), .dayOff)
        XCTAssertEqual(Headline(status: .stopped, overtime: false, agent: false, dayOff: false), .personal)
        XCTAssertFalse(Headline.dayOff.inWorkSession)
        XCTAssertTrue(Headline.idle.inWorkSession)
    }

    func testIdleSinceIsTheLastInput() throws {
        engine.appActivated(xcode)
        XCTAssertNil(engine.idleSince)
        time.advance(400)
        engine.tick(idleSeconds: 300)
        XCTAssertEqual(engine.idleSince, time.now.addingTimeInterval(-300))
        time.advance(10)
        engine.tick(idleSeconds: 1)
        XCTAssertNil(engine.idleSince)
    }

    func testManualModeRecordsOnlyExplicitSessions() throws {
        engine.updateSettings { $0.mode = .manual }
        engine.appActivated(slack)
        time.advance(100)
        XCTAssertEqual(engine.status, .stopped)
        XCTAssertTrue(try all().isEmpty)

        engine.start()
        time.advance(200)
        engine.stop()
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].kind, .work)
        XCTAssertEqual(sessions[0].source, .manual)
        XCTAssertEqual(sessions[0].categoryID, Store.workID)
        XCTAssertEqual(sessions[0].duration, 200, accuracy: 0.001)
    }

    func testManualSessionStillPausesWhenIdle() throws {
        engine.updateSettings { $0.mode = .manual }
        engine.appActivated(slack)
        engine.start()
        time.advance(1000)
        engine.tick(idleSeconds: 900)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(total(sessions, .work), 100, accuracy: 0.001)
        XCTAssertEqual(total(sessions, .idle), 900, accuracy: 0.001)
    }

    func testHybridOverrideNeverDoubleCounts() throws {
        engine.updateSettings { $0.mode = .hybrid }
        engine.appActivated(slack)
        time.advance(100)                    // automatic: non-work
        engine.start()                       // manual override: everything counts as work
        time.advance(200)
        engine.appActivated(xcode)
        time.advance(100)
        engine.stop()                        // back to automatic rules
        XCTAssertEqual(engine.status, .tracking(.work))
        time.advance(50)
        engine.appActivated(slack)
        time.advance(50)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.map(\.kind), [.nonwork, .work, .work, .work, .nonwork])
        XCTAssertEqual(sessions.map(\.source), [.automatic, .manual, .manual, .automatic, .automatic])
        XCTAssertEqual(total(sessions, .work), 350, accuracy: 0.001)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.duration }, 500, accuracy: 0.001, "automatic and manual tracking share one timeline")
        assertNoOverlap(sessions)
    }

    func testSwitchingModeEndsManualSession() throws {
        engine.updateSettings { $0.mode = .manual }
        engine.appActivated(slack)
        engine.start()
        time.advance(100)
        engine.updateSettings { $0.mode = .automatic }
        XCTAssertFalse(engine.manualActive)
        time.advance(100)
        engine.shutdown()

        XCTAssertEqual(try all().map(\.kind), [.work, .nonwork])
    }

    // MARK: Restart and crash recovery

    func testCompletedSessionsSurviveRestartAndCrashLosesOnlyUncheckpointedTime() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var disk = try Store(directory: directory)
        try disk.saveRule(AppRule(bundleID: xcode.bundleID, appName: xcode.name, categoryID: Store.workID))
        var engine = TrackingEngine(store: disk, time: time)
        engine.recover()
        engine.appActivated(xcode)
        time.advance(100)
        engine.tick(idleSeconds: 0)          // checkpoint at 100 s
        time.advance(10)                     // never checkpointed
        disk.close()                         // crash: no shutdown()

        time.advance(500)
        disk = try Store(directory: directory)
        engine = TrackingEngine(store: disk, time: time)
        engine.recover()
        var sessions = try disk.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].duration, 100, accuracy: 0.001, "only what was checkpointed is kept; nothing is made up")
        XCTAssertEqual(sessions[0].endReason, "recovered")

        engine.appActivated(xcode)
        time.advance(60)
        engine.shutdown()
        sessions = try disk.sessions()
        XCTAssertEqual(sessions.map { $0.duration.rounded() }, [100, 60])
        assertNoOverlap(sessions)
        disk.close()
    }

    func testRestoreFromBackupWhileTracking() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try Store(directory: directory)
        try disk.saveRule(AppRule(bundleID: xcode.bundleID, appName: xcode.name, categoryID: Store.workID))
        let engine = TrackingEngine(store: disk, time: time)
        engine.recover()
        engine.appActivated(xcode)
        time.advance(100)
        engine.checkpoint()
        let backup = try disk.backup()       // taken mid-session
        time.advance(100)

        engine.shutdown()
        try disk.restore(from: backup)
        engine.reload()
        time.advance(50)
        engine.shutdown()

        let sessions = try disk.sessions()
        XCTAssertEqual(sessions.map { $0.duration.rounded() }, [100, 50], "the restored state plus what was tracked afterwards")
        XCTAssertEqual(sessions.map(\.endReason), ["recovered", "quit"])
        assertNoOverlap(sessions)
        disk.close()
    }

    func testDeletingEverythingWhileTrackingStartsClean() throws {
        engine.updateSettings { $0.idleThreshold = 60 }
        engine.appActivated(xcode)
        time.advance(100)
        try engine.performEdit { try store.deleteEverything() }
        engine.reload()
        time.advance(30)
        engine.shutdown()

        let sessions = try all()
        XCTAssertEqual(sessions.count, 1, "no orphan rows survive the wipe")
        XCTAssertEqual(sessions[0].duration, 30, accuracy: 0.001)
        XCTAssertEqual(sessions[0].kind, .nonwork, "rules are gone, so the app is unclassified again")
        var fresh = AppSettings()
        fresh.workSessionStart = engine.settings.workSessionStart
        XCTAssertEqual(engine.settings, fresh, "settings are the defaults")
        XCTAssertNotNil(engine.workSessionStart, "the default Work profile has a work session")
    }

    // MARK: Manual corrections while tracking

    func testManualEditWhileTrackingKeepsTimelineConsistent() throws {
        engine.appActivated(xcode)
        time.advance(600)
        let start = at(monday, 9).addingTimeInterval(100)
        let correction = Session(start: start, end: start.addingTimeInterval(100), tzOffset: 0, kind: .nonwork,
                                 categoryID: Store.nonworkID, source: .entry, endReason: "manual")
        try engine.performEdit { try store.saveManual(correction) }
        time.advance(100)
        engine.shutdown()

        let sessions = try all()
        assertNoOverlap(sessions)
        XCTAssertEqual(total(sessions, .work), 600, accuracy: 0.001)
        XCTAssertEqual(total(sessions, .nonwork), 100, accuracy: 0.001)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.duration }, 700, accuracy: 0.001)
    }
}
