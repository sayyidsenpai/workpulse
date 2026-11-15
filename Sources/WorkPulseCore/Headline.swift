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

/// When the goal sound plays: once, when work reaches the goal the popover leads with (the weekly
/// goal in Flexible, the daily goal in Fixed hours). Never at launch, and never because the goal
/// moved to the work: a change of rule or goal (a lower goal, a day off) starts the count again.
public struct GoalCue: Sendable {
    private var reached: Bool?
    private var basis: Basis?
    private struct Basis: Equatable, Sendable {
        var flexible: Bool
        var target: TimeInterval?
    }

    public init() {}

    /// The goal is reached now (false before the first update).
    public var isReached: Bool { reached ?? false }

    /// Takes the state after a refresh; returns true when the sound should play.
    public mutating func update(reached now: Bool, flexible: Bool, target: TimeInterval?) -> Bool {
        let basis = Basis(flexible: flexible, target: target)
        if basis != self.basis { reached = nil }
        let play = reached == false && now
        reached = now
        self.basis = basis
        return play
    }
}
