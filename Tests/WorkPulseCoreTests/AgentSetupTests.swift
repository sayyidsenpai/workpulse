import XCTest
@testable import WorkPulseCore

/// Automatic hook setup must add and remove only its own entries.
final class AgentSetupTests: XCTestCase {
    var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("wp-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testClaudeCodeKeepsOtherSettingsAndHooks() throws {
        let config = AgentSetup.configURL("claude-code", home: home)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try Data(before.utf8).write(to: config)

        XCTAssertFalse(AgentSetup.isInstalled("claude-code", home: home))
        try AgentSetup.install("claude-code", home: home)
        try AgentSetup.install("claude-code", home: home)   // a second time changes nothing
        XCTAssertTrue(AgentSetup.isInstalled("claude-code", home: home))
        XCTAssertEqual(try String(contentsOf: AgentSetup.backupURL("claude-code", home: home), encoding: .utf8), before)

        var root = try json(config)
        XCTAssertEqual(root["model"] as? String, "opus")
        var hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"])
        XCTAssertEqual(hooks["Stop"]?.count, 2, "the user's own Stop hook stays")
        XCTAssertEqual(hooks["PreToolUse"]?.first?["matcher"] as? String, "*")

        try AgentSetup.undo("claude-code", home: home)
        XCTAssertFalse(AgentSetup.isInstalled("claude-code", home: home))
        root = try json(config)
        hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Array(hooks.keys), ["Stop"])
        XCTAssertEqual(root["model"] as? String, "opus")
    }

    func testClaudeCodeWithoutAFileAndWithABrokenFile() throws {
        try AgentSetup.install("claude-code", home: home)
        XCTAssertTrue(AgentSetup.isInstalled("claude-code", home: home))
        try AgentSetup.undo("claude-code", home: home)
        XCTAssertTrue(try json(AgentSetup.configURL("claude-code", home: home)).isEmpty)

        try Data("{ not json".utf8).write(to: AgentSetup.configURL("claude-code", home: home))
        XCTAssertThrowsError(try AgentSetup.install("claude-code", home: home))
        XCTAssertEqual(try String(contentsOf: AgentSetup.configURL("claude-code", home: home), encoding: .utf8), "{ not json", "a file that cannot be read is not changed")
    }

    func testCodexBlockIsAddedAndRemoved() throws {
        let config = AgentSetup.configURL("codex", home: home)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let before = "model = \"gpt-5\"\n\n[features]\nhooks = true\n"
        try Data(before.utf8).write(to: config)

        try AgentSetup.install("codex", home: home)
        try AgentSetup.install("codex", home: home)
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(before))
        XCTAssertEqual(text.components(separatedBy: "[[hooks.Stop]]").count, 2, "added once")
        XCTAssertTrue(text.contains(#"command = "sh \"$HOME/Library/Application Support/WorkPulse/agent-hook.sh\" codex done 2>/dev/null || true""#))

        try AgentSetup.undo("codex", home: home)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), before)
        XCTAssertEqual(AgentSetup.manualText("codex").components(separatedBy: "[[hooks.").count - 1, 8)
    }
}
