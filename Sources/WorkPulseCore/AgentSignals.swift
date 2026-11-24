import Foundation

/// Reads the "an AI agent is working" markers that agent hooks leave on disk.
///
/// A Claude Code or Codex hook writes the file `<directory>/<tool>.<session>` on every sign of life
/// (prompt submitted, tool call) and deletes it when the agent finishes its turn. The file holds
/// only the session's working folder. WorkPulse looks at which files exist, when they were last
/// written and that folder; it never reads prompts, transcripts or output.
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

    /// - Parameter folders: only sessions working inside one of these folders count; empty = all.
    /// - Returns: `agent`, the display name(s) of counted agents whose marker was touched within
    ///   `quiet` seconds, or nil; and `staleFor`, set when a counted marker had gone quiet for
    ///   longer than that (agent interrupted or crashed without saying so): how long ago it was
    ///   last touched, so the caller can end the session there instead of now. Stale markers are removed.
    ///   `sessions`: each counted working session, with the folder its hook reported (nil when unknown).
    public static func read(_ directory: URL, now: Date = Date(), quiet: TimeInterval, folders: [String] = [])
        -> (agent: String?, staleFor: TimeInterval?, sessions: [AgentSession]) {
        let fm = FileManager.default
        let directory = directory.resolvingSymlinksInPath()  // the data folder may be a symlink
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var tools = Set<String>()
        var sessions: [AgentSession] = []
        var staleFor: TimeInterval?
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            guard let touched = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            let age = now.timeIntervalSince(touched)
            let folder = sessionFolder(file)
            let counted = folders.isEmpty || folder.map { isInside($0, folders) } == true
            if age <= quiet {
                guard counted else { continue }
                let tool = String(file.lastPathComponent.prefix { $0 != "." })
                tools.insert(names[tool] ?? tool)
                sessions.append(AgentSession(agent: names[tool] ?? tool, folder: folder))
            } else {
                try? fm.removeItem(at: file)
                if counted { staleFor = min(staleFor ?? age, age) }
            }
        }
        return (tools.isEmpty ? nil : tools.sorted().joined(separator: " + "), staleFor, sessions)
    }

    /// The working folder the hook wrote into a marker, or nil (empty marker from an older hook,
    /// or a value that is not a JSON string body).
    static func sessionFolder(_ marker: URL) -> String? {
        guard let raw = try? String(contentsOf: marker, encoding: .utf8), !raw.isEmpty,
              let data = "[\"\(raw)\"]".data(using: .utf8),
              let path = (try? JSONSerialization.jsonObject(with: data) as? [String])?.first, path.hasPrefix("/") else { return nil }
        return path
    }

    /// True when `path` is one of `folders` or inside one, compared by whole path components
    /// after resolving symbolic links (`/tmp` is `/private/tmp`; `work` does not contain `work-old`).
    public static func isInside(_ path: String, _ folders: [String]) -> Bool {
        let parts = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return folders.contains { folder in
            let base = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return parts.count >= base.count && Array(parts.prefix(base.count)) == base
        }
    }
}

/// One agent session that is working now: the agent's display name and the folder it works in.
public struct AgentSession: Equatable, Sendable {
    public var agent: String
    /// The session's working folder; nil when its hook did not report one (an older hook).
    public var folder: String?

    public init(agent: String, folder: String?) {
        self.agent = agent
        self.folder = folder
    }
}

/// What the status card says while agents work: the title and one chip per folder.
public struct AgentDisplay: Equatable, Sendable {
    public struct Chip: Equatable, Sendable {
        /// "workpulse", "client-a/backend", or "Claude Code · workpulse" when several agents work.
        public var text: String
        /// The folder with `~` for the home folder, for the tooltip.
        public var path: String
        /// "Claude Code works in ~/dev/products/workpulse", for VoiceOver.
        public var label: String
    }

    public var title: String
    /// At most `maxChips`; the others are counted in `more`.
    public var chips: [Chip]
    /// "+2 more", or nil.
    public var more: String?
    /// The folders `more` stands for, for its tooltip.
    public var moreHelp: String?

    public static let maxChips = 2

    public init(_ sessions: [AgentSession], home: String = NSHomeDirectory()) {
        let agents = Set(sessions.map(\.agent))
        title = agents.count > 1 ? "\(agents.count) agents working" : "\(agents.first ?? "Agent") working"
        // One chip per agent and folder, in the order of the text the chips show.
        var seen = Set<String>()
        let known = sessions.compactMap { session in session.folder.map { (agent: session.agent, folder: $0) } }
            .filter { seen.insert($0.agent + "\u{0}" + $0.folder).inserted }
        func tilde(_ path: String) -> String {
            path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        // A folder name that two different folders share gets its parent folder too.
        let names = Dictionary(grouping: Set(known.map(\.folder)), by: { URL(fileURLWithPath: $0).lastPathComponent })
        let all: [Chip] = known.map { item in
            let url = URL(fileURLWithPath: item.folder)
            var name = url.lastPathComponent
            if (names[name]?.count ?? 0) > 1 { name = url.deletingLastPathComponent().lastPathComponent + "/" + name }
            return Chip(text: agents.count > 1 ? "\(item.agent) · \(name)" : name, path: tilde(item.folder),
                        label: "\(item.agent) works in \(tilde(item.folder))")
        }.sorted {
            let order = $0.text.localizedStandardCompare($1.text)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        chips = Array(all.prefix(Self.maxChips))
        let rest = all.dropFirst(Self.maxChips)
        more = rest.isEmpty ? nil : "+\(rest.count) more"
        moreHelp = rest.isEmpty ? nil : rest.map(\.path).joined(separator: ", ")
    }
}
