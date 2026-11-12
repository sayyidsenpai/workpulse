import XCTest
@testable import WorkPulseCore

final class StoreTests: XCTestCase {
    var directory: URL!

    override func setUp() { directory = temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func workHours(_ store: Store, _ day: LocalDay = monday) throws -> Double {
        (Aggregator.dayTotals(try store.sessions())[day]?.work ?? 0) / 3600
    }

    // MARK: Persistence

    func testEverythingPersistsAcrossReopen() throws {
        var store = try Store(directory: directory)
        try store.insert(makeSession(monday, 9, 10))
        try store.saveProject(Project(name: "Client A"))
        try store.saveCategory(WorkCategory(name: "Design", kind: .work))
        try store.saveRule(AppRule(bundleID: "com.figma.Desktop", appName: "Figma", categoryID: Store.workID, idleThreshold: 600))
        try store.saveGoal(GoalConfig(effectiveFrom: monday, dailyHours: 6, weeklyDays: 4, workingDays: [1, 2, 3, 4, 5, 6, 7]))
        try store.saveCompensation(Compensation(effectiveFrom: monday, monthlyAmount: 3000, currency: "EUR"))
        var settings = AppSettings()
        settings.mode = .hybrid
        settings.sleep.enabled = true
        settings.sleep.days = [2, 4]
        try store.saveSettings(settings)
        store.close()

        store = try Store(directory: directory)
        XCTAssertNil(store.recoveryNote)
        XCTAssertEqual(try store.sessions().count, 1)
        XCTAssertEqual(try store.projects().map(\.name), ["Client A"])
        XCTAssertEqual(try store.categories().map(\.name), ["Work", "Non-work", "Ignored", "Uncategorized", "Design"])
        XCTAssertEqual(try store.rules().first?.idleThreshold, 600)
        let goal = try XCTUnwrap(try store.goalConfigs().first)
        XCTAssertEqual(goal.dailyHours, 6)
        XCTAssertNil(goal.weeklyHours)
        XCTAssertEqual(goal.weeklyDays, 4)
        XCTAssertEqual(goal.workingDays, Set(1...7))
        XCTAssertEqual(try store.compensation().first?.currency, "EUR")
        XCTAssertEqual(try store.loadSettings(), settings)
        store.close()
    }

    func testSettingsDecodeToleratesMissingKeys() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"mode":"manual","idleThreshold":120}"#.utf8))
        XCTAssertEqual(old.mode, .manual)
        XCTAssertEqual(old.idleThreshold, 120)
        XCTAssertEqual(old.sleep, SleepSettings())
    }

    // MARK: Manual corrections

    func testManualSessionCarvesOverlappingSessions() throws {
        let store = try Store()
        try store.insert(makeSession(monday, 9, 12))

        // A hand-made session in the middle splits the existing one.
        var entry = makeSession(monday, 10, 11, kind: .idle)
        entry.source = .entry
        entry.id = try store.saveManual(entry)
        var sessions = try store.sessions()
        XCTAssertEqual(sessions.map { [$0.start, $0.end] }, [
            [at(monday, 9), at(monday, 10)], [at(monday, 10), at(monday, 11)], [at(monday, 11), at(monday, 12)],
        ])
        XCTAssertEqual(try workHours(store), 2, accuracy: 1e-6)

        // Correcting its start and end trims both neighbours.
        entry.start = at(monday, 9.5)
        entry.end = at(monday, 11.5)
        try store.saveManual(entry)
        sessions = try store.sessions()
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(try workHours(store), 1, accuracy: 1e-6)
        assertNoOverlap(sessions)

        // Growing it over everything removes what it fully covers.
        entry.start = at(monday, 8)
        entry.end = at(monday, 13)
        try store.saveManual(entry)
        XCTAssertEqual(try store.sessions().map(\.id), [entry.id])
        XCTAssertEqual(try workHours(store), 0, accuracy: 1e-6)
    }

    func testEditsImmediatelyChangeDerivedTotals() throws {
        let store = try Store()
        var s = makeSession(monday, 9, 11, kind: .nonwork)
        s.id = try store.insert(s)
        XCTAssertEqual(try workHours(store), 0)

        s.kind = .work                       // change category
        s.categoryID = Store.workID
        s.note = "client call"
        s.edited = true
        try store.saveManual(s)
        XCTAssertEqual(try workHours(store), 2, accuracy: 1e-6)
        XCTAssertEqual(try store.sessions().first?.note, "client call")

        s.end = at(monday, 10)               // correct the end time
        try store.saveManual(s)
        XCTAssertEqual(try workHours(store), 1, accuracy: 1e-6)

        try store.saveManual(makeSession(monday, 14, 16))  // create a missing session
        XCTAssertEqual(try workHours(store), 3, accuracy: 1e-6)

        try store.deleteSessions([s.id])     // delete an incorrect record
        XCTAssertEqual(try workHours(store), 2, accuracy: 1e-6)
    }

    func testInvalidIntervalIsRejected() throws {
        let store = try Store()
        XCTAssertThrowsError(try store.saveManual(makeSession(monday, 10, 10)))
        XCTAssertThrowsError(try store.saveManual(makeSession(monday, 11, 10)))
        XCTAssertTrue(try store.sessions().isEmpty)
    }

    func testSearchAndKindFilter() throws {
        let store = try Store()
        try store.saveProject(Project(name: "Apollo"))
        let project = try XCTUnwrap(try store.projects().first)
        var a = makeSession(monday, 9, 10, project: project.id)
        a.appName = "Xcode"
        var b = makeSession(monday, 10, 11, kind: .nonwork)
        b.appName = "Music"
        b.note = "focus playlist"
        try store.insert(a)
        try store.insert(b)

        XCTAssertEqual(try store.sessions(search: "xco").count, 1)
        XCTAssertEqual(try store.sessions(search: "playlist").map(\.appName), ["Music"])
        XCTAssertEqual(try store.sessions(search: "apollo").map(\.appName), ["Xcode"])
        XCTAssertEqual(try store.sessions(kinds: [.nonwork]).map(\.appName), ["Music"])
        XCTAssertEqual(try store.sessions(days: monday.adding(1)...monday.adding(1)).count, 0)
    }

    func testDeletingCategoryAndProjectKeepsSessions() throws {
        let store = try Store()
        try store.saveCategory(WorkCategory(name: "Design", kind: .work))
        try store.saveProject(Project(name: "Apollo"))
        let category = try XCTUnwrap(try store.categories().last)
        let project = try XCTUnwrap(try store.projects().first)
        var s = makeSession(monday, 9, 10, project: project.id)
        s.categoryID = category.id
        try store.insert(s)
        try store.saveRule(AppRule(bundleID: "x", appName: "X", categoryID: category.id, projectID: project.id))

        try store.deleteCategory(category.id)
        try store.deleteProject(project.id)
        let kept = try XCTUnwrap(try store.sessions().first)
        XCTAssertEqual(kept.kind, .work, "recorded time is untouched")
        XCTAssertEqual(kept.categoryID, Store.workID)
        XCTAssertNil(kept.projectID)
        XCTAssertEqual(try store.rules().first?.categoryID, Store.uncategorizedID)
        try store.deleteCategory(Store.workID)
        XCTAssertEqual(try store.categories().count, 4, "built-in categories cannot be deleted")
    }

    // MARK: Corruption, backup, recovery, deletion

    private func corruptDatabase() throws {
        let file = directory.appendingPathComponent("workpulse.sqlite")
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        try Data(repeating: 0x41, count: 8192).write(to: file)
    }

    func testCorruptDatabaseIsRestoredFromBackup() throws {
        var store = try Store(directory: directory)
        try store.insert(makeSession(monday, 9, 10))
        try store.backup()
        try store.insert(makeSession(monday, 11, 12))  // after the backup: will be lost
        store.close()
        try corruptDatabase()

        store = try Store(directory: directory)
        XCTAssertNotNil(store.recoveryNote)
        XCTAssertEqual(try store.sessions().count, 1, "restored from the newest healthy backup")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("corrupt-") }, "the damaged file is kept, not destroyed")
        try store.insert(makeSession(monday, 13, 14))
        XCTAssertEqual(try store.sessions().count, 2, "the recovered database is writable")
        store.close()
    }

    func testCorruptDatabaseWithoutBackupStartsFresh() throws {
        var store = try Store(directory: directory)
        try store.insert(makeSession(monday, 9, 10))
        store.close()
        try corruptDatabase()

        store = try Store(directory: directory)
        XCTAssertNotNil(store.recoveryNote)
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertEqual(try store.categories().count, 4)
        store.close()
    }

    func testDamagedBackupIsSkippedDuringRecovery() throws {
        var store = try Store(directory: directory)
        try store.insert(makeSession(monday, 9, 10))
        try store.backup(now: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = try store.backup(now: Date(timeIntervalSince1970: 1_700_100_000))
        store.close()
        try Data(repeating: 0x42, count: 4096).write(to: newer)
        try corruptDatabase()

        store = try Store(directory: directory)
        XCTAssertEqual(try store.sessions().count, 1, "falls back to the older, healthy backup")
        store.close()
    }

    func testBackupRestoreAndPruning() throws {
        let store = try Store(directory: directory)
        try store.insert(makeSession(monday, 9, 10))
        let backup = try store.backup(now: Date(timeIntervalSince1970: 1_700_000_000))
        try store.insert(makeSession(monday, 11, 12))
        XCTAssertEqual(try store.sessions().count, 2)

        try store.restore(from: backup)
        XCTAssertEqual(try store.sessions().count, 1)
        XCTAssertThrowsError(try store.restore(from: directory.appendingPathComponent("missing.sqlite")))
        XCTAssertEqual(try store.sessions().count, 1, "a failed restore leaves the live database intact")

        for i in 1...12 { try store.backup(now: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 60)) }
        XCTAssertEqual(store.backups().count, 10, "only the ten newest backups are kept")
        store.close()
    }

    func testUserControlledDeletion() throws {
        let store = try Store(directory: directory)
        try store.insert(makeSession(monday, 9, 10))
        try store.saveProject(Project(name: "Apollo"))
        try store.backup()

        try store.deleteAllSessions()
        XCTAssertTrue(try store.sessions().isEmpty)
        XCTAssertEqual(try store.projects().count, 1, "deleting history keeps configuration")

        try store.deleteEverything()
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(store.backups().isEmpty, "backups are deleted too")
        XCTAssertEqual(try store.categories().count, 4)
        XCTAssertEqual(try store.loadSettings(), AppSettings())
        store.close()
    }
}
