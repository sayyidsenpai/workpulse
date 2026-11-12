import XCTest
@testable import WorkPulseCore

/// AI agent work: engine classification, the on-disk signals, and the hook script itself.
final class AgentTests: XCTestCase {
    typealias App = TrackingEngine.FrontApp

    var store: Store!
    var time: FakeTime!
    var engine: TrackingEngine!
    var directory: URL!
    let xcode = App(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    let slack = App(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    override func setUpWithError() throws {
        store = try Store()
        try store.saveRule(AppRule(bundleID: xcode.bundleID, appName: xcode.name, categoryID: Store.workID))
        time = FakeTime(at(monday, 9))
        engine = TrackingEngine(store: store, time: time)
        engine.recover()
        directory = temporaryDirectory()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    // MARK: Engine

    func testAgentWorkCountsWhileUserIsIdleLockedOrInNonWorkApp() throws {
        engine.appActivated(slack)
        time.advance(100)                    // user's own non-work
        engine.setAgent("Claude Code")
        engine.setAgent("Claude Code")       // duplicate signal
        time.advance(400)
        engine.tick(idleSeconds: 400)        // user has been idle the whole time
        XCTAssertEqual(engine.status, .tracking(.work), "idle does not pause agent work")
        XCTAssertTrue(engine.agentWorking)
        time.advance(100)
        engine.screenLocked()                // nor does the lock screen
        time.advance(100)
        engine.setAgent(nil)                 // agent finished
        XCTAssertEqual(engine.status, .idle)
        time.advance(50)
        engine.shutdown()

        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map(\.kind), [.nonwork, .work, .idle])
        XCTAssertEqual(sessions.map { $0.duration.rounded() }, [100, 600, 50])
        XCTAssertEqual(sessions[1].source, .agent)
        XCTAssertEqual(sessions[1].appName, "Claude Code")
        XCTAssertEqual(sessions[1].categoryID, Store.workID)
        XCTAssertEqual(sessions.map(\.endReason), ["agent", "done", "quit"])
        assertNoOverlap(sessions)
    }

    func testUsersOwnWorkIsNeverCountedTwice() throws {
        engine.setAgent("Codex")
        engine.appActivated(xcode)           // own work: keeps its own application
        time.advance(100)
        engine.appActivated(slack)           // own non-work: the agent's work takes over
        time.advance(100)
        engine.appActivated(xcode)
        time.advance(100)
        engine.shutdown()

        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map(\.appName), ["Xcode", "Codex", "Xcode"])
        XCTAssertEqual(sessions.map(\.source), [.automatic, .agent, .automatic])
        XCTAssertEqual(total(sessions, .work), 300, accuracy: 0.001, "300 s elapsed, 300 s of work: not 600")
        assertNoOverlap(sessions)
    }

    func testAgentThatWentQuietIsEndedAtItsLastSignal() throws {
        engine.appActivated(slack)
        engine.setAgent("Codex")
        time.advance(1200)
        engine.setAgent(nil, endedAgo: 900)  // interrupted: last sign of life was 15 minutes ago
        engine.shutdown()

        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map(\.kind), [.work, .nonwork])
        XCTAssertEqual(sessions.map { $0.duration.rounded() }, [300, 900], "the silent 15 minutes are not kept as work")
        assertNoOverlap(sessions)
    }

    func testAgentWorkRespectsPauseStopSleepAndTheSetting() throws {
        engine.appActivated(slack)
        engine.pause()
        engine.setAgent("Claude Code")
        time.advance(100)
        XCTAssertTrue(try store.sessions().isEmpty, "paused means nothing is recorded")
        engine.resume()
        time.advance(100)
        engine.willSleep()
        time.now += 3600
        engine.didWake()
        time.advance(50)
        engine.updateSettings { $0.countAgentWork = false }
        time.advance(50)
        engine.stop()
        time.advance(100)
        engine.shutdown()

        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map(\.source), [.agent, .agent, .automatic])
        XCTAssertEqual(sessions.map(\.kind), [.work, .work, .nonwork])
        XCTAssertEqual(sessions.map { $0.duration.rounded() }, [100, 50, 50], "nothing while asleep, switched off, or stopped")
    }

    func testManualModeCountsAgentOnlyDuringASession() throws {
        engine.updateSettings { $0.mode = .manual }
        engine.setAgent("Claude Code")
        time.advance(100)
        XCTAssertTrue(try store.sessions().isEmpty)
    }

    // MARK: Signals on disk

    private func marker(_ name: String, age: TimeInterval, now: Date) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data().write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    func testSignalsReportBusyAgentsAndDropStaleOnes() throws {
        let now = Date()
        XCTAssertNil(AgentSignals.read(directory, now: now, quiet: 900).agent, "a missing folder means no agent")

        try marker("claude-code.abc", age: 10, now: now)
        XCTAssertEqual(AgentSignals.read(directory, now: now, quiet: 900).agent, "Claude Code")

        try marker("codex.019a", age: 100, now: now)
        try marker("claude-code.def", age: 5, now: now)
        try marker(".DS_Store", age: 5, now: now)
        let both = AgentSignals.read(directory, now: now, quiet: 900)
        XCTAssertEqual(both.agent, "Claude Code + Codex")
        XCTAssertNil(both.staleFor)

        // 20 minutes without a sign of life with a 15-minute limit: dropped, and reported with its age.
        try marker("codex.019a", age: 1200, now: now)
        let afterStale = AgentSignals.read(directory, now: now, quiet: 900)
        XCTAssertEqual(afterStale.agent, "Claude Code")
        XCTAssertEqual(afterStale.staleFor ?? 0, 1200, accuracy: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex.019a").path))
        XCTAssertNil(AgentSignals.read(directory, now: now, quiet: 900).staleFor, "reported once")
    }

    // MARK: Hook script

    private func runHook(_ arguments: [String], input: String) throws -> String {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/agent-hook.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path] + arguments
        process.environment = ["WORKPULSE_DATA_DIR": directory.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the hook must never fail the agent")
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testHookScriptCreatesAndRemovesMarkers() throws {
        let agents = directory.appendingPathComponent("agents")
        let input = #"{"session_id":"0199-ab_cd","transcript_path":"/x/y.jsonl","hook_event_name":"UserPromptSubmit","prompt":"secret text"}"#

        XCTAssertEqual(try runHook(["claude-code", "busy"], input: input), "", "it must print nothing: hook output can reach the agent")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agents.path), ["claude-code.0199-ab_cd"])
        XCTAssertEqual(try Data(contentsOf: agents.appendingPathComponent("claude-code.0199-ab_cd")).count, 0, "the marker is empty: no prompt text is stored")
        XCTAssertEqual(AgentSignals.read(agents, quiet: 900).agent, "Claude Code")

        // A second session of another tool, with multi-line JSON and a hostile session id.
        _ = try runHook(["codex", "busy"], input: "{\n  \"session_id\": \"../../etc/x y\",\n  \"cwd\": \"/tmp\"\n}")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agents.path).sorted(), ["claude-code.0199-ab_cd", "codex.etcxy"],
                       "the session id cannot escape the folder")

        XCTAssertEqual(try runHook(["claude-code", "done"], input: input), "")
        XCTAssertEqual(AgentSignals.read(agents, quiet: 900).agent, "Codex")

        // No usable input at all still works, as one shared marker per tool.
        _ = try runHook(["codex", "done"], input: "{\n  \"session_id\": \"../../etc/x y\"\n}")
        _ = try runHook(["codex", "busy"], input: "not json")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: agents.path), ["codex.session"])
        _ = try runHook(["codex", "done"], input: "")
        XCTAssertNil(AgentSignals.read(agents, quiet: 900).agent)
    }
}
