import XCTest
@testable import WorkPulseCore

/// Controllable clock: wall time and monotonic uptime can be moved together or apart.
final class FakeTime: TimeSource {
    var now: Date
    var uptime: TimeInterval = 5000
    var tzOffset = 0

    init(_ now: Date) { self.now = now }

    /// Normal passage of time: both clocks move.
    func advance(_ seconds: TimeInterval) {
        now += seconds
        uptime += seconds
    }
}

/// 4 March 2024, a Monday.
let monday = LocalDay(year: 2024, month: 3, day: 4)

/// `hour` o'clock local time on `day`, for a recording offset of `tz` seconds.
func at(_ day: LocalDay, _ hour: Double, tz: Int = 0) -> Date {
    Date(timeIntervalSince1970: Double(day.index) * 86400 + hour * 3600 - Double(tz))
}

func makeSession(_ day: LocalDay, _ from: Double, _ to: Double, kind: SessionKind = .work, project: Int64? = nil, tz: Int = 0) -> Session {
    Session(start: at(day, from, tz: tz), end: at(day, to, tz: tz), tzOffset: tz, kind: kind, projectID: project)
}

func temporaryDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workpulse-tests-\(UUID().uuidString)")
}

/// The core timeline invariant: sorted by start, no session begins before the previous one ended.
func assertNoOverlap(_ sessions: [Session], file: StaticString = #filePath, line: UInt = #line) {
    let sorted = sessions.sorted { $0.start < $1.start }
    for (a, b) in zip(sorted, sorted.dropFirst()) {
        XCTAssertGreaterThanOrEqual(b.start.timeIntervalSince(a.end), -0.001, "sessions \(a.id) and \(b.id) overlap", file: file, line: line)
    }
}

func total(_ sessions: [Session], _ kind: SessionKind) -> TimeInterval {
    sessions.filter { $0.kind == kind }.reduce(0) { $0 + $1.duration }
}
