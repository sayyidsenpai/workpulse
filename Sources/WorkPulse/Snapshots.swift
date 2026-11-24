#if DEBUG
import AppKit
import SwiftUI
import WorkPulseCore

extension AppModel {
    /// `WORKPULSE_DEMO=1` with `--snapshot`: pictures for the documentation. The front application
    /// is fixed (Xcode), the session clock is set by hand and the real application icon is used.
    /// Run it with a data folder that holds sample data, never with real data.
    static let demo = ProcessInfo.processInfo.environment["WORKPULSE_DEMO"] != nil

    /// Development aid, debug builds only (`WorkPulse --snapshot <folder>`): renders every screen
    /// to a PNG, in light and dark appearance, so the UI can be reviewed without screen capture.
    func snapshot(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Motion.off = true
        // A debug binary has no app bundle, so macOS gives it a generic icon: use the real one.
        if let icon = NSImage(contentsOfFile: "Packaging/AppIcon.icns") { NSApp.applicationIconImage = icon }
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            await capture(DashboardView().environment(self), size: nil, appearance: appearance,
                          to: folder.appendingPathComponent("dashboard\(suffix).png"))
            if let session = try? store.sessions().last(where: { $0.kind == .work }) {
                await capture(SessionEditor(session: session).environment(self), size: nil, appearance: appearance,
                              to: folder.appendingPathComponent("editor\(suffix).png"))
            }
            await capture(statesSheet(), size: nil, appearance: appearance, to: folder.appendingPathComponent("states\(suffix).png"))
            await capture(agentSheet(), size: nil, appearance: appearance, to: folder.appendingPathComponent("agent-folders\(suffix).png"))
            refresh()
            for step in 0..<4 {
                await capture(OnboardingView(step: step).environment(self), size: OnboardingView.size, appearance: appearance,
                              to: folder.appendingPathComponent("onboarding-\(step + 1)\(suffix).png"))
            }
            for tool in ["claude-code", "codex"] {
                await capture(AgentSetupSheet(tool: tool).environment(self), size: nil, appearance: appearance,
                              to: folder.appendingPathComponent("setup-\(tool)\(suffix).png"))
            }
            // Popover contents (a popover itself does not draw in an off-screen window).
            await capture(CurrencySearch { _ in }, size: nil, appearance: appearance,
                          to: folder.appendingPathComponent("currency-search\(suffix).png"))
            await capture(DatePicker("From", selection: .constant(Date().addingTimeInterval(10 * 86_400)), in: Date()...,
                                     displayedComponents: .date).datePickerStyle(.graphical).labelsHidden().padding(12),
                          size: nil, appearance: appearance, to: folder.appendingPathComponent("calendar\(suffix).png"))
            for tab in MainTab.allCases {
                self.tab = tab
                await capture(MainView().environment(self), size: NSSize(width: 1080, height: Self.demo ? 720 : 800), appearance: appearance,
                              to: folder.appendingPathComponent("\(tab.rawValue.lowercased())\(suffix).png"))
            }
            // Reports and Settings are longer than the window: one tall picture shows all of each.
            for tab in [MainTab.reports, .settings] {
                self.tab = tab
                await capture(MainView().environment(self), size: NSSize(width: 1080, height: 1700), appearance: appearance,
                              to: folder.appendingPathComponent("\(tab.rawValue.lowercased())-full\(suffix).png"))
            }
        }
        // The day-off flow changes the sample data: run it only when its pictures are wanted.
        if Self.demo, Self.only.map({ "dayoff work-full".contains($0) || $0.contains("dayoff") }) ?? true { await dayOffFlow(to: folder) }
    }

    /// Demo mode only (it changes the data): the day-off flow, step by step, and the Work screen in full.
    private func dayOffFlow(to folder: URL) async {
        let looks: [(String, NSAppearance.Name)] = [("", .aqua), ("-dark", .darkAqua)]
        // Each capture closes its window, which ends the one-time offer: set the state again each time.
        func shoot(_ name: String, offer: Bool = false, confirm: Bool = false) async {
            for (suffix, look) in looks {
                offerDayOff = offer
                confirmingDayOff = confirm
                await capture(DashboardView().environment(self), size: nil, appearance: look, to: folder.appendingPathComponent("\(name)\(suffix).png"))
            }
        }
        tab = .work
        for (suffix, look) in looks {
            await capture(MainView().environment(self), size: NSSize(width: 1080, height: 1240), appearance: look,
                          to: folder.appendingPathComponent("work-full\(suffix).png"))
        }
        endWork()
        refresh()
        await shoot("dayoff-1-offer", offer: true)
        await shoot("dayoff-1b-reopened")
        await shoot("dayoff-2-confirm", confirm: true)
        takeDayOff(moveWork: true)
        refresh()
        await shoot("dayoff-3-dayoff")
    }

    /// Every status the popover can show, side by side. The state is set by hand for the picture only.
    private func statesSheet() -> some View {
        var heroes: [Hero] = []
        func add(_ status: TrackingEngine.Status, overtime: Bool = false, agent: Bool = false, ask: Bool = false) {
            self.status = status
            isOvertime = overtime
            agentWorking = agent
            suggestion = ask ? Suggestion(app: "Xcode", minutes: 12) : nil
            // The overtime card as it looks after work hours: 42 minutes after a 16.00 end.
            let saved = (workHoursEnd, lastWorkHoursEnd, summary.overtime, summary.week, summary.weekGoalAt)
            if overtime {
                workHoursEnd = nil
                lastWorkHoursEnd = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date())
                summary.overtime = 42 * 60
                // Flexible: 1h 12m over the weekly goal, reached at 17.17.
                if flexible, let target = summary.week?.targetSeconds {
                    summary.week?.workSeconds = target + 72 * 60
                    summary.weekGoalAt = Calendar.current.date(bySettingHour: 17, minute: 17, second: 0, of: Date())
                }
            }
            heroes.append(hero)
            (workHoursEnd, lastWorkHoursEnd, summary.overtime, summary.week, summary.weekGoalAt) = saved
        }
        summary.sessionWork = 2712
        idleSince = Date().addingTimeInterval(-900)
        add(.tracking(.work))
        agentDisplay = AgentDisplay([AgentSession(agent: "Claude Code", folder: NSHomeDirectory() + "/dev/products/workpulse")])
        add(.tracking(.work), agent: true)
        add(.tracking(.work), overtime: true)
        add(.tracking(.nonwork))
        add(.idle)
        add(.personal)
        add(.personal, ask: true)
        add(.tracking(.excluded))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(364), spacing: 14), count: 4), spacing: 14) {
            ForEach(Array(heroes.enumerated()), id: \.offset) { HeroCard(hero: $0.element) }
        }
        .padding(14)
        .background(Wallpaper())
    }

    /// The agent card for each folder case, after work hours ended at 17.00.
    private func agentSheet() -> some View {
        let home = NSHomeDirectory()
        func s(_ agent: String, _ folder: String?) -> AgentSession { AgentSession(agent: agent, folder: folder.map { home + $0 }) }
        let cases: [[AgentSession]] = [
            [s("Claude Code", "/dev/products/workpulse")],
            [s("Claude Code", "/dev/products/workpulse"), s("Claude Code", "/dev/clients/storefront-api")],
            [s("Claude Code", "/dev/products/workpulse"), s("Codex", "/dev/clients/storefront-api")],
            [s("Claude Code", "/dev/clients/a-very-long-client-project-name-for-acme-backend-api")],
            [s("Claude Code", "/dev/client-a/backend"), s("Claude Code", "/dev/client-b/backend")],
            ["workpulse", "storefront-api", "billing-web", "scripts"].map { s("Claude Code", "/dev/" + $0) },
            [s("Claude Code", nil)],
        ]
        let saved = (status, agentWorking, isOvertime, workHoursEnd, lastWorkHoursEnd, agentDisplay)
        status = .tracking(.work); agentWorking = true; isOvertime = false
        workHoursEnd = nil
        lastWorkHoursEnd = Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date())
        summary.sessionWork = 253
        var heroes: [Hero] = []
        for sessions in cases {
            agentDisplay = AgentDisplay(sessions)
            heroes.append(hero)
        }
        (status, agentWorking, isOvertime, workHoursEnd, lastWorkHoursEnd, agentDisplay) = saved
        // Each card at its own height, as in the popover.
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(364), spacing: 14, alignment: .top), count: 4), alignment: .leading, spacing: 14) {
            ForEach(Array(heroes.enumerated()), id: \.offset) { HeroCard(hero: $0.element).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .background(Wallpaper())
    }

    /// `--only <text>` renders only the pictures whose file name contains the text.
    private static let only: String? = {
        let arguments = CommandLine.arguments
        return arguments.firstIndex(of: "--only").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }()

    private func capture(_ view: some View, size: NSSize?, appearance: NSAppearance.Name, to url: URL) async {
        if let only = Self.only, !url.lastPathComponent.contains(only) { return }
        FileHandle.standardError.write(Data("snapshot \(url.lastPathComponent)\n".utf8))
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))  // off screen
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.7))  // let onAppear-driven loads finish
        if Self.demo { summary.sessionWork = 2712 }
        try? await Task.sleep(for: .seconds(0.8))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.close()
    }
}
#endif
