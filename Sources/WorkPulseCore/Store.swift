import Foundation
import SQLite3
import os

let log = Logger(subsystem: "com.workpulse.app", category: "core")

public struct StoreError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Local persistence. One SQLite file (WAL), integrity-checked on open, with automatic
/// recovery from the newest healthy backup when the file is damaged.
public final class Store {
    // Built-in category ids (seeded, not deletable).
    public static let workID: Int64 = 1
    public static let nonworkID: Int64 = 2
    public static let ignoredID: Int64 = 3
    public static let uncategorizedID: Int64 = 4

    /// Data folder; nil for an in-memory store.
    public let directory: URL?
    /// Set when the database had to be recovered on open; shown to the user once.
    public private(set) var recoveryNote: String?
    private var db: Database

    /// In-memory store: tests, and the fallback when disk storage is unavailable.
    public init() throws {
        directory = nil
        db = try Database(path: ":memory:")
        try migrate()
    }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("workpulse.sqlite")
        var note: String?
        var opened: Database
        do {
            opened = try Self.openChecked(file)
        } catch let failure as DBError where failure.isCorruption {
            // Only a genuinely damaged file is quarantined; busy/permission errors propagate.
            log.error("database damaged: \(failure.description, privacy: .public)")
            note = try Self.recover(file, in: directory)
            opened = try Self.openChecked(file)
        }
        db = opened
        recoveryNote = note
        try migrate()
    }

    public func close() { db.close() }

    public var databaseURL: URL? { directory?.appendingPathComponent("workpulse.sqlite") }

    // MARK: - Opening, integrity, recovery

    private static func openChecked(_ file: URL, wal: Bool = true) throws -> Database {
        let db = try Database(path: file.path)
        if wal { try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;") }
        let check = try db.run("PRAGMA quick_check(1)").first?.first as? String
        guard check == "ok" else {
            throw DBError(code: SQLITE_CORRUPT, message: "integrity check failed: \(check ?? "no result")")
        }
        return db
    }

    private static func isHealthy(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path) && (try? openChecked(file, wal: false)) != nil
    }

    /// Moves the damaged database aside and restores the newest healthy backup, if any.
    private static func recover(_ file: URL, in directory: URL) throws -> String {
        let fm = FileManager.default
        let quarantine = "corrupt-\(Int(Date().timeIntervalSince1970)).sqlite"
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: file.path + suffix) {
            try fm.moveItem(atPath: file.path + suffix, toPath: directory.appendingPathComponent(quarantine).path + suffix)
        }
        for backup in backups(in: directory) where isHealthy(backup) {
            try fm.copyItem(at: backup, to: file)
            return "The database was damaged and has been restored from the backup “\(backup.lastPathComponent)”. The damaged file was kept as \(quarantine)."
        }
        return "The database was damaged and no usable backup was found, so a new one was started. The damaged file was kept as \(quarantine)."
    }

    private func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS sessions(
            id INTEGER PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, tz_offset INTEGER NOT NULL,
            kind TEXT NOT NULL, bundle_id TEXT, app_name TEXT, category_id INTEGER, project_id INTEGER,
            source TEXT NOT NULL, edited INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '',
            end_reason TEXT NOT NULL DEFAULT '', CHECK(end >= start));
        CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start);
        CREATE INDEX IF NOT EXISTS sessions_end ON sessions(end);
        CREATE TABLE IF NOT EXISTS categories(
            id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, builtin INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS projects(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
        CREATE TABLE IF NOT EXISTS app_rules(
            bundle_id TEXT PRIMARY KEY, app_name TEXT NOT NULL, category_id INTEGER NOT NULL,
            idle_threshold INTEGER, project_id INTEGER);
        CREATE TABLE IF NOT EXISTS goals(
            id INTEGER PRIMARY KEY, project_id INTEGER, effective_from INTEGER NOT NULL,
            daily_hours REAL, weekly_hours REAL, monthly_hours REAL, weekly_days INTEGER,
            min_day_minutes INTEGER NOT NULL, working_days INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS compensation(
            id INTEGER PRIMARY KEY, effective_from INTEGER NOT NULL, monthly_amount REAL NOT NULL, currency TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT OR IGNORE INTO categories(id, name, kind, builtin) VALUES
            (1, 'Work', 'work', 1), (2, 'Non-work', 'nonwork', 1), (3, 'Ignored', 'excluded', 1), (4, 'Uncategorized', 'nonwork', 1);
        """)
        // Added in 1.1. Rows from earlier versions have NULL: Fixed hours with the current work hours,
        // so their reports do not change.
        let columns = Set(try db.run("PRAGMA table_info(goals)").compactMap { $0[1] as? String })
        for (name, type) in [("overtime", "TEXT"), ("start_minutes", "INTEGER"), ("end_minutes", "INTEGER")] where !columns.contains(name) {
            try db.exec("ALTER TABLE goals ADD COLUMN \(name) \(type)")
        }
        // Versions saved before 1.1 get the work hours in force now, once, so a later change of the
        // hours does not rewrite their reports. Hours that were off are stored as 0 to 0: no work hours.
        // Every version saved since stores its own hours, so this finds nothing after the first open.
        if try db.run("SELECT 1 FROM goals WHERE start_minutes IS NULL LIMIT 1").first != nil {
            let hours = try loadSettings().schedule
            let (start, end) = hours.isUsable ? (hours.startMinutes, hours.endMinutes) : (0, 0)
            try db.run("UPDATE goals SET start_minutes=?, end_minutes=? WHERE start_minutes IS NULL", [start, end])
        }
    }

    // MARK: - Sessions

    private static let columns = "id,start,end,tz_offset,kind,bundle_id,app_name,category_id,project_id,source,edited,note,end_reason"

    private func params(_ s: Session) -> [Any?] {
        [s.start.timeIntervalSince1970, s.end.timeIntervalSince1970, s.tzOffset, s.kind.rawValue, s.bundleID, s.appName,
         s.categoryID, s.projectID, s.source.rawValue, s.edited, s.note, s.endReason]
    }

    private func session(_ r: [Any?]) -> Session {
        Session(id: int(r[0]), start: Date(timeIntervalSince1970: num(r[1])), end: Date(timeIntervalSince1970: num(r[2])),
                tzOffset: Int(int(r[3])), kind: SessionKind(rawValue: r[4] as? String ?? "") ?? .nonwork,
                bundleID: r[5] as? String, appName: r[6] as? String, categoryID: r[7] as? Int64, projectID: r[8] as? Int64,
                source: TrackingSource(rawValue: r[9] as? String ?? "") ?? .automatic, edited: int(r[10]) != 0,
                note: r[11] as? String ?? "", endReason: r[12] as? String ?? "")
    }

    @discardableResult
    public func insert(_ s: Session) throws -> Int64 {
        try db.run("INSERT INTO sessions(start,end,tz_offset,kind,bundle_id,app_name,category_id,project_id,source,edited,note,end_reason) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", params(s))
        return db.lastInsertID
    }

    public func update(_ s: Session) throws {
        try db.run("UPDATE sessions SET start=?,end=?,tz_offset=?,kind=?,bundle_id=?,app_name=?,category_id=?,project_id=?,source=?,edited=?,note=?,end_reason=? WHERE id=?", params(s) + [s.id as Any?])
    }

    public func updateEnd(_ id: Int64, end: Date, reason: String) throws {
        try db.run("UPDATE sessions SET end=?, end_reason=? WHERE id=?", [end.timeIntervalSince1970, reason, id])
    }

    public func deleteSessions(_ ids: [Int64]) throws {
        try db.transaction {
            for id in ids { try db.run("DELETE FROM sessions WHERE id=?", [id]) }
        }
    }

    /// Moves sessions recorded as non-work to work: the user confirmed that this time was work.
    /// The reverse of `markAsWork`: the user says this work time was not work (a day off).
    public func markAsNonwork(_ ids: [Int64]) throws {
        try db.transaction {
            for id in ids { try db.run("UPDATE sessions SET kind='nonwork' WHERE id=? AND kind='work'", [id]) }
        }
    }

    public func markAsWork(_ ids: [Int64]) throws {
        try db.transaction {
            for id in ids { try db.run("UPDATE sessions SET kind='work' WHERE id=? AND kind='nonwork'", [id]) }
        }
    }

    /// Sessions overlapping [from, to), oldest first. `search` matches app, note, project and category.
    public func sessions(from: Date? = nil, to: Date? = nil, search: String = "", kinds: Set<SessionKind>? = nil) throws -> [Session] {
        var sql = "SELECT \(Self.columns) FROM sessions WHERE 1=1"
        var params: [Any?] = []
        if let from { sql += " AND end > ?"; params.append(from.timeIntervalSince1970) }
        if let to { sql += " AND start < ?"; params.append(to.timeIntervalSince1970) }
        if let kinds { sql += " AND kind IN (" + kinds.map { "'\($0.rawValue)'" }.joined(separator: ",") + ")" }
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty {
            sql += " AND (app_name LIKE ? OR note LIKE ? OR project_id IN (SELECT id FROM projects WHERE name LIKE ?) OR category_id IN (SELECT id FROM categories WHERE name LIKE ?))"
            params += Array(repeating: "%\(term)%" as Any?, count: 4)
        }
        return try db.run(sql + " ORDER BY start", params).map(session)
    }

    /// Sessions that have any time on the given local days.
    public func sessions(days: ClosedRange<LocalDay>, search: String = "", kinds: Set<SessionKind>? = nil) throws -> [Session] {
        // Pad by a day each side: recorded UTC offsets span -12h…+14h.
        let from = Date(timeIntervalSince1970: Double(days.lowerBound.index - 1) * 86400)
        let to = Date(timeIntervalSince1970: Double(days.upperBound.index + 2) * 86400)
        return try sessions(from: from, to: to, search: search, kinds: kinds).filter { s in
            Aggregator.split(s).contains { days.contains($0.day) }
        }
    }

    public func latestEnd() throws -> Date? {
        (try db.run("SELECT MAX(end) FROM sessions").first?.first ?? nil).map { Date(timeIntervalSince1970: num($0)) }
    }

    public func firstDay() throws -> LocalDay? {
        try db.run("SELECT start, tz_offset FROM sessions ORDER BY start LIMIT 1").first.map {
            LocalDay(date: Date(timeIntervalSince1970: num($0[0])), tzOffset: Int(int($0[1])))
        }
    }

    /// After a crash or power loss the open row still holds its last checkpoint. Keep it as is
    /// (nothing is invented past the checkpoint) and drop rows too short to mean anything.
    public func recoverUnclosed() throws {
        try db.exec("""
        DELETE FROM sessions WHERE end_reason = '' AND end - start < 1.0;
        UPDATE sessions SET end_reason = 'recovered' WHERE end_reason = '';
        """)
    }

    /// Inserts (id 0) or updates a hand-edited session. Manual corrections win: overlapping parts
    /// of other sessions are trimmed, split or removed so the timeline never double-counts.
    @discardableResult
    public func saveManual(_ s: Session) throws -> Int64 {
        guard s.end > s.start else { throw StoreError(message: "The end time must be after the start time.") }
        return try db.transaction {
            for other in try sessions(from: s.start, to: s.end) where other.id != s.id {
                if other.start >= s.start && other.end <= s.end {
                    try db.run("DELETE FROM sessions WHERE id=?", [other.id])
                } else if other.start < s.start && other.end > s.end {
                    var tail = other
                    tail.start = s.end
                    try insert(tail)
                    try db.run("UPDATE sessions SET end=? WHERE id=?", [s.start.timeIntervalSince1970, other.id])
                } else if other.start < s.start {
                    try db.run("UPDATE sessions SET end=? WHERE id=?", [s.start.timeIntervalSince1970, other.id])
                } else {
                    try db.run("UPDATE sessions SET start=? WHERE id=?", [s.end.timeIntervalSince1970, other.id])
                }
            }
            if s.id == 0 { return try insert(s) }
            try update(s)
            return s.id
        }
    }

    /// Bundle ids and names of every application seen so far.
    public func knownApps() throws -> [(bundleID: String, name: String)] {
        try db.run("SELECT bundle_id, MAX(app_name) FROM sessions WHERE bundle_id IS NOT NULL GROUP BY bundle_id").map {
            (bundleID: $0[0] as? String ?? "", name: $0[1] as? String ?? "")
        }
    }

    // MARK: - Categories, projects, rules

    public func categories() throws -> [WorkCategory] {
        try db.run("SELECT id,name,kind,builtin FROM categories ORDER BY builtin DESC, CASE WHEN builtin THEN id END, name").map {
            WorkCategory(id: int($0[0]), name: $0[1] as? String ?? "", kind: SessionKind(rawValue: $0[2] as? String ?? "") ?? .nonwork, builtin: int($0[3]) != 0)
        }
    }

    public func saveCategory(_ c: WorkCategory) throws {
        if c.id == 0 {
            try db.run("INSERT INTO categories(name, kind) VALUES (?, ?)", [c.name, c.kind.rawValue])
        } else {
            try db.run("UPDATE categories SET name=?, kind=? WHERE id=? AND builtin=0", [c.name, c.kind.rawValue, c.id])
        }
    }

    public func deleteCategory(_ id: Int64) throws {
        try db.transaction {
            try db.run("UPDATE app_rules SET category_id=4 WHERE category_id=?", [id])
            try db.run("UPDATE sessions SET category_id = CASE kind WHEN 'work' THEN 1 ELSE 4 END WHERE category_id=?", [id])
            try db.run("DELETE FROM categories WHERE id=? AND builtin=0", [id])
        }
    }

    public func projects() throws -> [Project] {
        try db.run("SELECT id, name FROM projects ORDER BY name").map { Project(id: int($0[0]), name: $0[1] as? String ?? "") }
    }

    public func saveProject(_ p: Project) throws {
        if p.id == 0 {
            try db.run("INSERT INTO projects(name) VALUES (?)", [p.name])
        } else {
            try db.run("UPDATE projects SET name=? WHERE id=?", [p.name, p.id])
        }
    }

    public func deleteProject(_ id: Int64) throws {
        try db.transaction {
            try db.run("UPDATE sessions SET project_id=NULL WHERE project_id=?", [id])
            try db.run("UPDATE app_rules SET project_id=NULL WHERE project_id=?", [id])
            try db.run("DELETE FROM goals WHERE project_id=?", [id])
            try db.run("DELETE FROM projects WHERE id=?", [id])
        }
    }

    public func rules() throws -> [AppRule] {
        try db.run("SELECT bundle_id, app_name, category_id, idle_threshold, project_id FROM app_rules ORDER BY app_name").map {
            AppRule(bundleID: $0[0] as? String ?? "", appName: $0[1] as? String ?? "", categoryID: int($0[2]),
                    idleThreshold: ($0[3] as? Int64).map(Int.init), projectID: $0[4] as? Int64)
        }
    }

    public func saveRule(_ r: AppRule) throws {
        try db.run("INSERT OR REPLACE INTO app_rules(bundle_id, app_name, category_id, idle_threshold, project_id) VALUES (?,?,?,?,?)",
                   [r.bundleID, r.appName, r.categoryID, r.idleThreshold, r.projectID])
    }

    public func deleteRule(_ bundleID: String) throws {
        try db.run("DELETE FROM app_rules WHERE bundle_id=?", [bundleID])
    }

    // MARK: - Goals and compensation (versioned by effective date)

    public func goalConfigs() throws -> [GoalConfig] {
        try db.run("SELECT id, project_id, effective_from, daily_hours, weekly_hours, monthly_hours, weekly_days, min_day_minutes, working_days, overtime, start_minutes, end_minutes FROM goals ORDER BY effective_from").map { r in
            let mask = int(r[8])
            return GoalConfig(id: int(r[0]), projectID: r[1] as? Int64, effectiveFrom: LocalDay(index: Int(int(r[2]))),
                              dailyHours: optNum(r[3]), weeklyHours: optNum(r[4]), monthlyHours: optNum(r[5]),
                              weeklyDays: (r[6] as? Int64).map(Int.init), minDayMinutes: Int(int(r[7])),
                              workingDays: Set((1...7).filter { mask & (1 << ($0 - 1)) != 0 }),
                              overtime: (r[9] as? String).flatMap(OvertimeRule.init(rawValue:)) ?? .fixed,
                              startMinutes: (r[10] as? Int64).map(Int.init), endMinutes: (r[11] as? Int64).map(Int.init))
        }
    }

    /// Saves a goal version. A version already starting on the same day for the same profile is replaced.
    public func saveGoal(_ g: GoalConfig) throws {
        let mask = g.workingDays.reduce(0) { $0 | (1 << ($1 - 1)) }
        try db.transaction {
            try db.run("DELETE FROM goals WHERE effective_from=? AND project_id IS ?", [g.effectiveFrom.index, g.projectID])
            try db.run("INSERT INTO goals(project_id, effective_from, daily_hours, weekly_hours, monthly_hours, weekly_days, min_day_minutes, working_days, overtime, start_minutes, end_minutes) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                       [g.projectID, g.effectiveFrom.index, g.dailyHours, g.weeklyHours, g.monthlyHours, g.weeklyDays, g.minDayMinutes, mask,
                        g.overtime.rawValue, g.startMinutes, g.endMinutes])
        }
    }

    public func deleteGoal(_ id: Int64) throws {
        try db.run("DELETE FROM goals WHERE id=?", [id])
    }

    public func compensation() throws -> [Compensation] {
        try db.run("SELECT id, effective_from, monthly_amount, currency FROM compensation ORDER BY effective_from").map {
            Compensation(id: int($0[0]), effectiveFrom: LocalDay(index: Int(int($0[1]))), monthlyAmount: num($0[2]), currency: $0[3] as? String ?? "")
        }
    }

    public func saveCompensation(_ c: Compensation) throws {
        try db.transaction {
            try db.run("DELETE FROM compensation WHERE effective_from=?", [c.effectiveFrom.index])
            try db.run("INSERT INTO compensation(effective_from, monthly_amount, currency) VALUES (?,?,?)", [c.effectiveFrom.index, c.monthlyAmount, c.currency])
        }
    }

    public func deleteCompensation(_ id: Int64) throws {
        try db.run("DELETE FROM compensation WHERE id=?", [id])
    }

    // MARK: - Settings

    public func loadSettings() throws -> AppSettings {
        guard let json = try db.run("SELECT value FROM settings WHERE key='app'").first?.first as? String else { return AppSettings() }
        return (try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))) ?? AppSettings()
    }

    public func saveSettings(_ s: AppSettings) throws {
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO settings(key, value) VALUES ('app', ?)", [json])
    }

    // MARK: - Backup, restore, deletion

    public static func backups(in directory: URL) -> [URL] {
        let folder = directory.appendingPathComponent("Backups")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // Names embed a sortable timestamp; newest first.
        return files.filter { $0.lastPathComponent.hasPrefix("workpulse-") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public func backups() -> [URL] { directory.map(Self.backups(in:)) ?? [] }

    /// Writes a consistent snapshot into Backups/ and keeps the ten newest.
    @discardableResult
    public func backup(now: Date = Date()) throws -> URL {
        guard let directory else { throw StoreError(message: "An in-memory store cannot be backed up.") }
        let fm = FileManager.default
        let folder = directory.appendingPathComponent("Backups")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let destination = folder.appendingPathComponent("workpulse-\(stamp.string(from: now)).sqlite")
        try? fm.removeItem(at: destination)
        try db.run("VACUUM INTO ?", [destination.path])
        for old in backups().dropFirst(10) { try? fm.removeItem(at: old) }
        return destination
    }

    /// Replaces the live database with a backup. The previous database is kept as pre-restore-*.sqlite.
    public func restore(from backup: URL) throws {
        guard let directory, let file = databaseURL else { throw StoreError(message: "An in-memory store cannot be restored.") }
        guard Self.isHealthy(backup) else { throw StoreError(message: "The selected file is not a healthy WorkPulse backup.") }
        let fm = FileManager.default
        db.close()  // checkpoints and removes the WAL
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: file.path + suffix) }
        let previous = directory.appendingPathComponent("pre-restore-\(Int(Date().timeIntervalSince1970)).sqlite")
        try fm.moveItem(at: file, to: previous)
        do {
            try fm.copyItem(at: backup, to: file)
        } catch {
            try? fm.moveItem(at: previous, to: file)
            db = try Self.openChecked(file)
            throw error
        }
        db = try Self.openChecked(file)
        try migrate()
    }

    /// Deletes all recorded activity but keeps rules, goals and settings.
    public func deleteAllSessions() throws {
        try db.exec("DELETE FROM sessions")
        try purge()
    }

    /// Deletes everything WorkPulse has stored, including backups and quarantined files.
    public func deleteEverything() throws {
        try db.exec("""
        DELETE FROM sessions; DELETE FROM app_rules; DELETE FROM goals; DELETE FROM compensation;
        DELETE FROM projects; DELETE FROM settings; DELETE FROM categories;
        """)
        try migrate()
        try purge()
        guard let directory else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: directory.appendingPathComponent("Backups"))
        for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = file.lastPathComponent
            if name.hasPrefix("corrupt-") || name.hasPrefix("pre-restore-") { try? fm.removeItem(at: file) }
        }
    }

    /// Rewrites the file so deleted rows are really gone from disk, not just unlinked.
    private func purge() throws {
        try db.exec("VACUUM")
        if directory != nil { try db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    }
}

private func num(_ v: Any?) -> Double { (v as? Double) ?? Double(v as? Int64 ?? 0) }
private func optNum(_ v: Any?) -> Double? { v == nil ? nil : num(v) }
private func int(_ v: Any?) -> Int64 { (v as? Int64) ?? Int64(v as? Double ?? 0) }
