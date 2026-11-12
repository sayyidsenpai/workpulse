import SwiftUI
import WorkPulseCore

/// The menu bar popover: status, live totals, goal progress and the tracking controls.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }
            if model.engine.clockBehind {
                Text("The system clock is behind the latest recorded session. New time is appended after it until the clock catches up.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            currentActivity
            Divider()
            totals
            Divider()
            controls
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(model.statusColor).frame(width: 9, height: 9)
            Text(model.statusText).font(.headline).lineLimit(1)
            Spacer()
            Picker("Tracking mode", selection: model.binding(\.mode)) {
                ForEach(TrackingMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Automatic: track by application rules. Manual: track only between Start and Stop. Hybrid: automatic, plus manual sessions that count everything as work.")
        }
    }

    private var currentActivity: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.frontApp?.name ?? "No active application").lineLimit(1)
                Live { now in
                    Text(model.sessionStart.map { "Current session \(Fmt.clock(now.timeIntervalSince($0)))" } ?? "No active session")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let app = model.frontApp, Browsers.isBrowser(app.bundleID) {
                    Text("Browser: tabs and sites are not read. Its category applies to all browsing.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let app = model.frontApp {
                Picker("Category", selection: categoryBinding(app)) {
                    ForEach(model.categories) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                .help("How time in \(app.name) is classified from now on")
            }
        }
    }

    private func categoryBinding(_ app: TrackingEngine.FrontApp) -> Binding<Int64> {
        Binding(get: { model.rule(for: app.bundleID)?.categoryID ?? Store.uncategorizedID },
                set: { id in
                    var rule = model.rule(for: app.bundleID) ?? AppRule(bundleID: app.bundleID, appName: app.name)
                    rule.categoryID = id
                    model.setRule(rule)
                })
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 8) {
            GoalRow(title: "Today", result: model.summary.day)
            GoalRow(title: "This week", result: model.summary.week)
            GoalRow(title: "This month", result: model.summary.month)
            if let week = model.summary.week {
                HStack {
                    Text("Working days this week")
                    Spacer()
                    Text(week.daysTarget.map { "\(week.workingDays) of \($0)" } ?? "\(week.workingDays)").monospacedDigit()
                }
                .font(.callout)
            }
            let today = model.summary.today
            Text("Today · active apps \(Fmt.duration(today.active)) · idle \(Fmt.duration(today.idle)) · excluded \(Fmt.duration(today.excluded))")
                .font(.caption).foregroundStyle(.secondary)
                .help("Active application time is all time an app was in front while you were present. Work time is the part classified as work. Idle and excluded time are never counted as work.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                let engine = model.engine
                let _ = model.status  // re-evaluate the buttons whenever tracking state changes
                // In hybrid mode with automatic tracking already on, Start begins a manual work session.
                let startsSession = model.settings.mode == .manual || (model.settings.mode == .hybrid && model.settings.autoEnabled)
                if engine.canStart {
                    Button(startsSession && model.settings.mode == .hybrid ? "Start Session" : "Start") { engine.start() }
                        .help(startsSession ? "Count everything as work until you stop" : "Turn automatic tracking on")
                }
                if engine.canPause { Button("Pause") { engine.pause() }.help("Record nothing until you resume") }
                if engine.canResume { Button("Resume") { engine.resume() } }
                if engine.canStop {
                    Button("Stop") { engine.stop() }
                        .help(engine.manualActive && model.settings.mode == .hybrid ? "End the manual session and return to automatic rules" : "Stop tracking")
                }
                Spacer()
            }
            if !model.projects.isEmpty {
                HStack {
                    Text("Project")
                    Spacer()
                    Picker("Project", selection: model.binding(\.activeProjectID)) {
                        Text("No project").tag(Int64?.none)
                        ForEach(model.projects) { Text($0.name).tag(Int64?.some($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                    .help("Project (work profile) that new work time is filed under")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                footerButton(tab.rawValue, tab.symbol) { model.showMain(tab) }
            }
            footerButton("Quit", "power") { NSApp.terminate(nil) }
        }
    }

    private func footerButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

/// One period's work time with optional goal progress, counting live while work is tracked.
struct GoalRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let result: PeriodResult?

    var body: some View {
        Live { now in
            let live = model.isWorking ? max(0, now.timeIntervalSince(model.summary.asOf)) : 0
            let work = (result?.workSeconds ?? 0) + live
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(Fmt.duration(work)).monospacedDigit().fontWeight(.medium)
                }
                if let target = result?.targetSeconds, target > 0 {
                    ProgressView(value: min(1, work / target))
                    Text(work >= target ? "Goal of \(Fmt.duration(target)) reached" : "\(Fmt.duration(target - work)) left of \(Fmt.duration(target))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
