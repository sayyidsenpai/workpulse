import Foundation

/// What the popover, the menu bar icon and the menu bar text say about the current state.
/// The one place that decides it, so the three always agree. When several apply, the order of
/// the checks below is the precedence: Overtime is said before an agent working.
public enum Headline: Equatable, Sendable {
    case overtime, agent, tracking, nonwork, ignored, idle, waiting, personal, dayOff

    public init(status: TrackingEngine.Status, overtime: Bool, agent: Bool, dayOff: Bool) {
        switch status {
        case .tracking(.work): self = overtime ? .overtime : agent ? .agent : .tracking
        case .tracking(.nonwork): self = .nonwork
        case .tracking(.excluded): self = .ignored
        case .tracking(.idle), .idle: self = .idle
        case .waiting: self = .waiting
        case .personal, .stopped: self = dayOff ? .dayOff : .personal
        }
    }

    /// The Work profile is on: there is a work session (see `AppSettings.workSessionStart`).
    public var inWorkSession: Bool { self != .personal && self != .dayOff }
}

extension TrackingEngine {
    public var headline: Headline {
        Headline(status: status, overtime: isOvertime, agent: agentWorking, dayOff: isDayOffToday)
    }
}
