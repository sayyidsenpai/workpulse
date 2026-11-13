import Foundation

/// Adds the WorkPulse hook to the configuration of Claude Code or Codex, and removes it again.
///
/// It changes only its own entries (every one contains `WorkPulse/agent-hook.sh`), keeps a copy
/// of the file from before the first change, and never touches a file it cannot read.
public enum AgentSetup {
    static let marker = "WorkPulse/agent-hook.sh"
    static let blockStart = "# >>> WorkPulse hooks (added by WorkPulse) >>>"
    static let blockEnd = "# <<< WorkPulse hooks <<<"

    /// Hook events per tool: the state the hook reports, and whether the event takes a matcher.
    static func events(_ tool: String) -> [(event: String, state: String, matcher: Bool)] {
        var list = [("UserPromptSubmit", "busy", false), ("PreToolUse", "busy", true), ("PostToolUse", "busy", true), ("Stop", "done", false)]
        if tool == "claude-code" { list.append(("SessionEnd", "done", false)) }
        return list.map { (event: $0.0, state: $0.1, matcher: $0.2) }
    }

    static func command(_ tool: String, _ state: String) -> String {
        "sh \"$HOME/Library/Application Support/WorkPulse/agent-hook.sh\" \(tool) \(state) 2>/dev/null || true"
    }

    public static func configURL(_ tool: String, home: URL) -> URL {
        home.appendingPathComponent(tool == "codex" ? ".codex/config.toml" : ".claude/settings.json")
    }

    public static func backupURL(_ tool: String, home: URL) -> URL {
        let config = configURL(tool, home: home)
        return config.deletingLastPathComponent().appendingPathComponent(config.lastPathComponent + ".workpulse-backup")
    }

    public static func isInstalled(_ tool: String, home: URL) -> Bool {
        (try? String(contentsOf: configURL(tool, home: home), encoding: .utf8))?.contains(marker) ?? false
    }

    /// The text to add by hand: the same entries `install` writes.
    public static func manualText(_ tool: String) -> String {
        if tool == "codex" { return codexBlock() }
        let object = ["hooks": claudeHooks(into: [:])]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Adds the hook entries. Does nothing if they are there already.
    public static func install(_ tool: String, home: URL) throws {
        guard !isInstalled(tool, home: home) else { return }
        let config = configURL(tool, home: home)
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: config.path) ? try Data(contentsOf: config) : nil
        let output: Data
        if tool == "codex" {
            var text = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            if !text.isEmpty { text += "\n" }
            output = Data((text + codexBlock() + "\n").utf8)
        } else {
            var root = try existing.map(jsonObject) ?? [:]
            guard let hooks = (root["hooks"] ?? [String: Any]()) as? [String: Any] else {
                throw StoreError(message: "\"hooks\" in \(config.lastPathComponent) is not an object. WorkPulse did not change the file.")
            }
            root["hooks"] = claudeHooks(into: hooks)
            output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing {
            let backup = backupURL(tool, home: home)
            try? fm.removeItem(at: backup)
            try existing.write(to: backup, options: .atomic)
        }
        try output.write(to: config, options: .atomic)
    }

    /// Removes the WorkPulse entries and nothing else.
    public static func undo(_ tool: String, home: URL) throws {
        let config = configURL(tool, home: home)
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        let data = try Data(contentsOf: config)
        let output: Data
        if tool == "codex" {
            let text = String(decoding: data, as: UTF8.self)
            guard let start = text.range(of: blockStart), let end = text.range(of: blockEnd, range: start.upperBound..<text.endIndex) else { return }
            var kept = String(text[..<start.lowerBound]) + text[end.upperBound...].drop { $0 == "\n" }
            while kept.hasSuffix("\n\n") { kept.removeLast() }
            output = Data(kept.utf8)
        } else {
            var root = try jsonObject(data)
            guard var hooks = root["hooks"] as? [String: Any] else { return }
            for (event, value) in hooks {
                guard let entries = value as? [[String: Any]] else { continue }
                let kept: [[String: Any]] = entries.compactMap { entry in
                    guard let inner = entry["hooks"] as? [[String: Any]] else { return entry }
                    let rest = inner.filter { !(($0["command"] as? String) ?? "").contains(marker) }
                    if rest.isEmpty { return nil }
                    var entry = entry
                    entry["hooks"] = rest
                    return entry
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            root["hooks"] = hooks.isEmpty ? nil : hooks
            output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        try output.write(to: config, options: .atomic)
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw StoreError(message: "The configuration file is not valid JSON. WorkPulse did not change it.")
        }
        return object
    }

    private static func claudeHooks(into hooks: [String: Any]) -> [String: Any] {
        var hooks = hooks
        for item in events("claude-code") {
            var entry: [String: Any] = ["hooks": [["type": "command", "timeout": 5, "command": command("claude-code", item.state)]]]
            if item.matcher { entry["matcher"] = "*" }
            hooks[item.event] = ((hooks[item.event] as? [Any]) ?? []) + [entry]
        }
        return hooks
    }

    private static func codexBlock() -> String {
        var lines = [blockStart]
        for item in events("codex") {
            let escaped = command("codex", item.state).replacingOccurrences(of: "\"", with: "\\\"")
            lines += ["[[hooks.\(item.event)]]", "", "[[hooks.\(item.event).hooks]]", "type = \"command\"", "command = \"\(escaped)\"", "timeout = 5", ""]
        }
        lines[lines.count - 1] = blockEnd
        return lines.joined(separator: "\n")
    }
}
