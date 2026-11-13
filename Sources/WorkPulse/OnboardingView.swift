import AppKit
import SwiftUI
import WorkPulseCore

/// First-launch setup in four steps: welcome, work day, work applications, recap.
/// Nothing is stored until the user selects Start WorkPulse.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step = 0
    @State private var schedule = WorkSchedule(enabled: true, days: [2, 3, 4, 5, 6], startMinutes: 8 * 60, endMinutes: 16 * 60)
    @State private var goal = WorkDayEditor.defaultGoal
    @State private var apps: [AppRow] = []
    /// Bundle identifiers of the applications that count as work.
    @State private var ticked: Set<String> = []
    @State private var launchAtLogin = true

    private static let rowHeight: CGFloat = 54

    /// `step` selects the first step shown (0…3); snapshots use it.
    init(step: Int = 0) { _step = State(initialValue: step) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch step {
                case 0: welcome
                case 1: workDay
                case 2: applications
                default: ready
                }
            }
            .padding(.top, 10).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, 40).padding(.bottom, 18)
        .frame(width: 760, height: 640)
        // The layout owns the whole window, title bar included: `header` is the title bar row.
        // If the window is ever taller, the content stays at the top, in line with the window buttons.
        .frame(maxHeight: .infinity, alignment: .top)
        .background { ZStack { Glass(); Wallpaper().opacity(0.85) }.ignoresSafeArea() }
        .ignoresSafeArea()
        .onAppear(perform: load)
    }

    // MARK: - Frame

    /// The title bar row (28 pt), to the right of the window buttons.
    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
            Text("WorkPulse").font(WP.font(15, .bold)).tracking(-0.2).foregroundStyle(WP.ink)
            Spacer(minLength: 12)
            Text("Step \(step + 1) of 4").font(WP.font(12, .semibold)).monospacedDigit().foregroundStyle(WP.secondary)
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(index <= step ? WP.cobalt : WP.track).frame(width: index == step ? 22 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : WP.spring, value: step)
            .accessibilityHidden(true)   // "Step n of 4" says the same in text
        }
        .padding(.leading, 38)   // clears the window buttons
        .frame(height: 28)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button { step -= 1 } label: { Text("Back").frame(minWidth: 72) }
                    .buttonStyle(WPButtonStyle(height: 40, radius: 10))
                    .keyboardShortcut("[", modifiers: .command)
            }
            ZStack {
                if step == 1 && !schedule.enabled {
                    Label("WorkPulse stays in Personal until you select Start work.", systemImage: "info.circle.fill")
                        .font(WP.font(12)).foregroundStyle(WP.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            Button {
                if step < 3 { step += 1 } else { finish() }
            } label: {
                HStack(spacing: 8) {
                    if step == 3 { Image(systemName: "play.fill").font(WP.font(11)).accessibilityHidden(true) }
                    Text(step == 3 ? "Start WorkPulse" : "Continue")
                }
                .frame(minWidth: step == 3 ? 136 : 108)
            }
            .buttonStyle(WPButtonStyle(kind: .primary, height: 40, radius: 10))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { line }
    }

    private var line: some View { Rectangle().fill(WP.hairline).frame(height: 1) }

    // MARK: - Step 1: welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to WorkPulse").font(WP.font(32, .bold)).tracking(-0.6).foregroundStyle(WP.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("WorkPulse counts your work time. It also tells you when you can stop.")
                    .font(WP.font(15)).foregroundStyle(WP.secondary)
            }
            .wpRise(0)
            Spacer(minLength: 12)
            VStack(spacing: 10) {
                feature("stopwatch", WP.cobalt, WP.onCobalt, "It counts work automatically",
                        "In work hours, time in your work applications counts as work.")
                feature("clock", WP.navy, WP.onNavy, "It tells you when to stop",
                        "You see when you reach your goal and when work hours end.")
                feature("checkmark.shield", WP.green, WP.greenBg, "Your data stays on this Mac",
                        "No account. No network. No keys, screen content, tabs, or URLs.")
            }
            .wpRise(1)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                menuBarPicture
                menuBarPointer
            }
            .wpRise(2)
            Spacer(minLength: 0)
        }
    }

    private func feature(_ symbol: String, _ fill: Color, _ ink: Color, _ title: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            tile(symbol, fill: fill, ink: ink, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(WP.font(14, .semibold)).foregroundStyle(WP.ink)
                Text(text).font(WP.font(14)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .wpCard(padding: 14, strong: true)
        .accessibilityElement(children: .combine)
    }

    private func tile(_ symbol: String, fill: Color = WP.cobalt, ink: Color = WP.onCobalt, size: CGFloat = 34) -> some View {
        Image(systemName: symbol).font(WP.font(size >= 40 ? 20 : 15, .semibold)).foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }

    /// The right end of the menu bar with the real WorkPulse item (the same symbol and text) and the real time.
    private var menuBarPicture: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(systemName: model.statusSymbol)
                if let text = model.menuBarText { Text(text).monospacedDigit() }
            }
            .font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
            .padding(.horizontal, 8).frame(height: 24)
            .background(WP.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WP.cobalt, lineWidth: 2).padding(-4))
            TimelineView(.everyMinute) { context in
                Text("\(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))  \(Fmt.time(context.date))")
                    .font(WP.font(13, .medium)).monospacedDigit().foregroundStyle(WP.secondary)
            }
        }
        .padding(.horizontal, 14).frame(height: 36)
        .background(WP.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WP.hairline))
        .accessibilityElement()
        .accessibilityLabel("The menu bar, with the WorkPulse item")
    }

    private var menuBarPointer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.up.right").font(WP.font(12, .bold)).foregroundStyle(WP.textBlue).accessibilityHidden(true)
            Text("WorkPulse is in the menu bar, at the top of your screen. Select the WorkPulse item to open it.")
                .font(WP.font(14)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 2: work day

    private var workDay: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Set your work day",
                         subtitle: "WorkPulse has two profiles. In Work, it counts work time. In Personal, it counts no work time.")
                .wpRise(0)
            WorkDayEditor(schedule: $schedule, goal: $goal, firstWeekday: model.settings.firstWeekday)
                .wpCard(padding: 12, strong: true)
                .wpRise(1)
        }
    }

    /// The goal as the editor shows it: never longer than the work hours.
    private var shownGoal: Int {
        min(max(30, goal), schedule.enabled ? max(30, schedule.lengthMinutes / 30 * 30) : 720)
    }

    // MARK: - Step 3: work applications

    private var applications: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Select your work applications",
                         subtitle: "In the Work profile, time in these applications counts as work. You can change this later in Apps.")
                .wpRise(0)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in appRow(app) }
                }
            }
            .frame(maxHeight: CGFloat(apps.count) * Self.rowHeight)   // a short list does not leave an empty card
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .wpCard(padding: 0, strong: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Work applications")
            .wpRise(1)
            Note(text: "WorkPulse does not read tabs or URLs. If a browser counts as work, all time in the browser counts in the Work profile.")
                .wpRise(2)
        }
    }

    private func appRow(_ app: AppRow) -> some View {
        Toggle(isOn: Binding(get: { ticked.contains(app.id) },
                             set: { if $0 { ticked.insert(app.id) } else { ticked.remove(app.id) } })) {
            HStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 34, height: 34).accessibilityHidden(true)
                } else {
                    AppTile(name: app.name, size: 34)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.name).font(WP.font(14, .semibold)).foregroundStyle(WP.ink).lineLimit(1)
                    Text(Browsers.isBrowser(app.id) ? "Browser" : app.running ? "Open now" : "Used before")
                        .font(WP.font(12)).foregroundStyle(WP.caption)
                }
            }
        }
        .toggleStyle(WPSwitchStyle())
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .overlay(alignment: .top) { if app.id != apps.first?.id { line } }
    }

    /// The running applications and the installed applications that WorkPulse saw before, without WorkPulse.
    /// Only applications that already have the Work category start as work: WorkPulse makes no guess.
    private func load() {
        guard apps.isEmpty else { return }
        if model.settings.schedule.isUsable { schedule = model.settings.schedule }
        goal = model.dailyGoalMinutes ?? goal
        var rows: [String: AppRow] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
            rows[id] = AppRow(id: id, name: app.localizedName ?? id, icon: app.icon, running: true)
        }
        for app in (try? model.store.knownApps()) ?? [] where rows[app.bundleID] == nil && app.bundleID != Bundle.main.bundleIdentifier {
            // Not installed (or an agent, which is not an application): not in the list.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { continue }
            rows[app.bundleID] = AppRow(id: app.bundleID, name: app.name.isEmpty ? app.bundleID : app.name,
                                        icon: NSWorkspace.shared.icon(forFile: url.path), running: false)
        }
        apps = rows.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        ticked = Set(apps.map(\.id).filter { model.rule(for: $0)?.categoryID == Store.workID })
    }

    // MARK: - Step 4: recap

    private var ready: some View {
        let work = apps.filter { ticked.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ScreenHeader(title: "You are ready", subtitle: "You can change all settings later.").wpRise(0)
            Spacer(minLength: 12)
            VStack(spacing: 0) {
                recap("calendar", "Work days", Self.daysText(schedule.days, firstWeekday: model.settings.firstWeekday))
                line
                recap("clock", "Work hours", schedule.enabled
                      ? "\(Fmt.time(minutes: schedule.startMinutes)) to \(Fmt.time(minutes: schedule.endMinutes))\(schedule.endMinutes < schedule.startMinutes ? ", next day" : "")"
                      : "No schedule. You start work with a button.")
                line
                recap("target", "Daily goal", "\(Fmt.minutes(shownGoal)) of work for each work day")
                line
                recap("square.grid.2x2", "Work applications",
                      work.isEmpty ? "None. You can add them later in Apps." : work.count == 1 ? "1 application" : "\(work.count) applications",
                      detail: work.isEmpty ? nil : work.map(\.name).joined(separator: ", "))
            }
            .wpCard(padding: 0, strong: true)
            .wpRise(1)
            Spacer(minLength: 12)
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Launch at login").font(WP.font(14, .semibold)).foregroundStyle(WP.ink)
                    Text("WorkPulse starts when you log in to this Mac.").font(WP.font(13)).foregroundStyle(WP.secondary)
                }
            }
            .toggleStyle(WPSwitchStyle())
            .wpCard(padding: 14, strong: true)
            .wpRise(2)
            Spacer(minLength: 12)
            menuBarPointer.wpRise(3)
            Spacer(minLength: 0)
        }
    }

    private func recap(_ symbol: String, _ label: String, _ value: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            tile(symbol)
            VStack(alignment: .leading, spacing: 0) {
                FieldLabel(label)
                Text(value).font(WP.font(14, .semibold)).monospacedDigit().foregroundStyle(WP.ink)
                if let detail { Text(detail).font(WP.font(12)).foregroundStyle(WP.caption).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// "Mon to Fri" for three or more days in a row, "Each day" for all seven, else "Mon, Wed".
    /// Days are 1 = Sunday … 7 = Saturday, shown in the order of the user's week.
    static func daysText(_ days: Set<Int>, firstWeekday: Int) -> String {
        let order = (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
        let on = order.indices.filter { days.contains(order[$0]) }
        let names = on.map { Calendar.current.shortWeekdaySymbols[order[$0] - 1] }
        guard let first = on.first, let last = on.last else { return "None" }
        if on.count == 7 { return "Each day" }
        if on.count > 2 && last - first + 1 == on.count { return "\(names[0]) to \(names[names.count - 1])" }
        return names.joined(separator: ", ")
    }

    private func finish() {
        // The switch must do its work in both directions: an application that the user set to Off loses the Work category.
        for app in apps where !ticked.contains(app.id) {
            guard var rule = model.rule(for: app.id), rule.categoryID == Store.workID else { continue }
            rule.categoryID = Store.uncategorizedID
            model.setRule(rule)
        }
        model.finishOnboarding(schedule: schedule, goalMinutes: shownGoal,
                               workApps: apps.filter { ticked.contains($0.id) }.map { (bundleID: $0.id, name: $0.name) },
                               launchAtLogin: launchAtLogin)
    }
}

private struct AppRow: Identifiable {
    /// Bundle identifier.
    let id: String
    let name: String
    let icon: NSImage?
    let running: Bool
}
