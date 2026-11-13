import Foundation

/// Reads the "an AI agent is working" markers that agent hooks leave on disk.
///
/// A Claude Code or Codex hook touches an empty file `<directory>/<tool>.<session>` on every sign
/// of life (prompt submitted, tool call) and deletes it when the agent finishes its turn.
/// WorkPulse looks only at which files exist and when they were last touched; it never reads
/// prompts, transcripts or output.
public enum AgentSignals {
    static let names = ["claude-code": "Claude Code", "codex": "Codex"]
    /// The agents WorkPulse can detect, by the name their hook passes.
    public static let tools = ["claude-code", "codex"]

    public static func name(_ tool: String) -> String { names[tool] ?? tool }

    /// When the hook of `tool` last ran, or nil if it never did: the agent is not connected.
    /// The hook touches `.seen-<tool>` on every call; a working marker counts as well.
    public static func lastSignal(_ tool: String, in directory: URL) -> Date? {
        let fm = FileManager.default
        let directory = directory.resolvingSymlinksInPath()
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent == ".seen-\(tool)" || $0.lastPathComponent.hasPrefix("\(tool).") }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }

    /// - Returns: `agent`, the display name(s) of agents whose marker was touched within `quiet`
    ///   seconds, or nil; and `staleFor`, set when a marker had gone quiet for longer than that
    ///   (agent interrupted or crashed without saying so): how long ago it was last touched, so
    ///   the caller can end the session there instead of now. Stale markers are removed.
    public static func read(_ directory: URL, now: Date = Date(), quiet: TimeInterval) -> (agent: String?, staleFor: TimeInterval?) {
        let fm = FileManager.default
        let directory = directory.resolvingSymlinksInPath()  // the data folder may be a symlink
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var tools = Set<String>()
        var staleFor: TimeInterval?
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            guard let touched = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            let age = now.timeIntervalSince(touched)
            if age <= quiet {
                let tool = String(file.lastPathComponent.prefix { $0 != "." })
                tools.insert(names[tool] ?? tool)
            } else {
                try? fm.removeItem(at: file)
                staleFor = min(staleFor ?? age, age)
            }
        }
        return (tools.isEmpty ? nil : tools.sorted().joined(separator: " + "), staleFor)
    }
}
