import AppKit
import WorkPulseCore

/// Feeds macOS activity into the tracking engine.
///
/// Everything here is event-driven except one self-rescheduling timer: 30 s while nothing is
/// happening, tighter only when the idle threshold is about to be reached or while waiting for
/// the user to come back. It uses no permission-gated API: the frontmost application comes
/// from NSWorkspace and the idle time from the HID event counter (no event contents, no keys).
@MainActor
final class ActivityMonitor {
    private let engine: TrackingEngine
    private var timer: Timer?
    private let ignored: Set<String> = [Bundle.main.bundleIdentifier ?? "com.workpulse.app", "com.apple.loginwindow"]
    var onTick: (() -> Void)?
    /// Folder where agent hooks leave their "working" markers; nil = agent detection off.
    var agentsDirectory: URL?
    private var agentsWatcher: DispatchSourceFileSystemObject?

    init(engine: TrackingEngine) { self.engine = engine }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        on(workspace, NSWorkspace.didActivateApplicationNotification) { $0.poll() }
        on(workspace, NSWorkspace.willSleepNotification) { $0.engine.willSleep() }
        on(workspace, NSWorkspace.didWakeNotification) { $0.engine.didWake(); $0.poll() }
        on(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.engine.screenLocked() }
        on(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.engine.screenUnlocked(); $0.poll() }
        on(workspace, NSWorkspace.willPowerOffNotification) { $0.engine.checkpoint() }
        let distributed = DistributedNotificationCenter.default()
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.engine.screenLocked() }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.engine.screenUnlocked(); $0.poll() }
        on(.default, .NSSystemClockDidChange) { $0.engine.clockChanged(); $0.poll() }
        on(.default, .NSSystemTimeZoneDidChange) { $0.poll() }
        watchAgents()
        poll()
    }

    /// Reacts the moment an agent starts or finishes (a marker file appears or disappears),
    /// instead of waiting for the next timer tick.
    private func watchAgents() {
        guard let directory = agentsDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        agentsWatcher = source
    }

    private func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (ActivityMonitor) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
    }

    /// Seconds since the last keyboard or mouse event in this login session.
    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Reads the current state, advances the engine and schedules the next check.
    func poll() {
        // Re-reading the frontmost app on every poll also heals any missed activation event.
        // WorkPulse's own windows don't count: time spent in them stays with the previous app.
        if let app = NSWorkspace.shared.frontmostApplication,
           let id = app.bundleIdentifier ?? app.localizedName, !ignored.contains(id) {
            engine.appActivated(.init(bundleID: id, name: app.localizedName ?? id))
        }
        if let directory = agentsDirectory {
            let signals = AgentSignals.read(directory, quiet: Double(engine.settings.agentQuietMinutes) * 60)
            engine.setAgent(signals.agent, endedAgo: signals.staleFor ?? 0)
        }
        let idle = idleSeconds
        engine.tick(idleSeconds: idle)
        onTick?()

        timer?.invalidate()
        let delay = engine.nextCheckDelay(idleSeconds: idle)
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        next.tolerance = delay * 0.1
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
