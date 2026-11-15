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
    @State private var rule = OvertimeRule.flexible
    @State private var apps: [AppRow] = []
    /// Bundle identifiers of the applications that count as work.
    @State private var ticked: Set<String> = []
    @State private var launchAtLogin = true

    /// The height of one row in the application list.
    private static let rowHeight: CGFloat = 58

    /// The size of the onboarding window. The view fills it: the window is the dialog card of the design.
    /// The height is what step 2 needs (the tallest step), plus 4 pt.
    static let size = NSSize(width: 640, height: 624)

    /// `step` selects the first step shown (0…3); snapshots use it.
    init(step: Int = 0) { _step = State(initialValue: step) }

    var body: some View {
        VStack(spacing: 20) {
            header
            Group {
                switch step {
                case 0: welcome
                case 1: workDay
                case 2: applications
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // each step is centred between header and footer
            footer
        }
        // 28 pt on all sides: the header starts right of and below the close button (x 13…27, y 6…20).
        .padding(28)
        // The window sets the height (Self.size, title bar included). A fixed height here made the
        // window grow by the title bar height, which left an empty band below the content.
        .frame(width: Self.size.width)
        .frame(maxHeight: .infinity)
        .background { Backdrop() }
        .ignoresSafeArea()
        .onAppear(perform: load)
    }

    // MARK: - Frame

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("WorkPulse").font(WP.font(15, .bold)).tracking(-0.15).foregroundStyle(WP.ink)
            Spacer(minLength: 12)
            Text("Step \(step + 1) of 4").font(WP.font(12, .semibold)).monospacedDigit().foregroundStyle(WP.secondary)
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule().fill(index <= step ? WP.cobalt : WP.sliderTrack).frame(width: index == step ? 22 : 6, height: 6)
                }
            }
            .animation(reduceMotion ? nil : WP.spring, value: step)
            .accessibilityHidden(true)   // "Step n of 4" says the same in text
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button { step -= 1 } label: {
                    Text("Back").font(WP.font(14, .medium)).frame(minWidth: 72)   // 96 pt with the padding of the style
                }
                .buttonStyle(WPButtonStyle(height: 40, radius: 10))
                .keyboardShortcut("[", modifiers: .command)
            }
            Spacer(minLength: 0)
            Button {
                if step < 3 { step += 1 } else { finish() }
            } label: {
                HStack(spacing: 8) {
                    if step == 3 { Image(systemName: "play.fill").font(WP.font(12)).accessibilityHidden(true) }
                    Text(step == 3 ? "Start WorkPulse" : "Continue")
                }
                .frame(minWidth: step == 3 ? 116 : 88).padding(.horizontal, 10)   // 160 and 132 pt at the least
            }
            .buttonStyle(WPButtonStyle(kind: .primary, height: 40, radius: 10))
            .shadow(color: WP.cobalt.opacity(step == 3 ? 0.3 : 0.25), radius: 5, y: 4)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { line }
    }

    private var line: some View { Rectangle().fill(WP.hairline).frame(height: 1) }

    /// The title of a step with one paragraph below it.
    private func heading(_ title: String, _ text: String, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(WP.font(large ? 32 : 24, .bold)).tracking(large ? -0.64 : -0.48).foregroundStyle(WP.ink)
                .accessibilityAddTraits(.isHeader)
            Text(text).font(WP.font(large ? 15 : 14)).lineSpacing(3).foregroundStyle(WP.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A square with a symbol. The text colour belongs to the fill colour.
    private func tile(_ symbol: String, fill: Color = WP.cobalt, ink: Color = WP.onCobalt, size: CGFloat = 34) -> some View {
        Image(systemName: symbol).font(WP.font(size >= 40 ? 19 : 15, .semibold)).foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size >= 40 ? 10 : 8, style: .continuous))
            .accessibilityHidden(true)
    }

    // MARK: - Step 1: welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Welcome to WorkPulse", "WorkPulse counts your work time. It also tells you when you can stop.", large: true)
                .wpRise(0)
            VStack(spacing: 10) {
                feature("stopwatch", WP.cobalt, WP.onCobalt, "It counts work automatically",
                        "In the Work profile, time in your work applications counts as work.")
                feature("clock", WP.navy, WP.onNavy, "It tells you when to stop",
                        "You see when you reach your goal. A long day can make a short day later.")
                feature("checkmark.shield", WP.green, WP.greenBg, "Your data stays on this Mac",
                        "No account. No network. No keys, screen content, tabs, or URLs.")
            }
            .wpRise(1)
            VStack(alignment: .leading, spacing: 8) {
                menuBarPicture
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.up.right").font(WP.font(13, .bold)).foregroundStyle(WP.textBlue).accessibilityHidden(true)
                    Text("WorkPulse is in the menu bar, at the top of your screen. Select the WorkPulse item to open it.")
                        .font(WP.font(14)).lineSpacing(3).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .wpRise(2)
        }
    }

    private func feature(_ symbol: String, _ fill: Color, _ ink: Color, _ title: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            tile(symbol, fill: fill, ink: ink, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(WP.font(14, .semibold)).foregroundStyle(WP.ink)
                Text(text).font(WP.font(14)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .wpCard(padding: 14, strong: true)
        .accessibilityElement(children: .combine)
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
            .background(WP.track, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            // The ring that points at the item: 2 pt of the field colour, then 2 pt cobalt.
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WP.field, lineWidth: 2).padding(-2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WP.cobalt, lineWidth: 2).padding(-4))
            TimelineView(.everyMinute) { context in
                // As in the menu bar: "Thu 12 Nov", without a comma.
                Text("\(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).replacingOccurrences(of: ",", with: ""))  \(Fmt.time(context.date))")
                    .font(WP.font(13, .medium)).monospacedDigit().foregroundStyle(WP.secondary)
            }
        }
        .padding(.horizontal, 14).frame(height: 36)
        .background(WP.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WP.hairline))
        .accessibilityElement()
        .accessibilityLabel("The menu bar, with the WorkPulse item")
    }

    // MARK: - Step 2: work day

    private var workDay: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Set your work day", "\(OvertimeChoice.label) You can change this later in Work.")
                .wpRise(0)
            OvertimeChoice(rule: $rule, large: true)
                .wpRise(1)
            HStack(alignment: .center, spacing: 20) {
                VStack(spacing: 6) {
                    WorkDial(start: $schedule.startMinutes, end: $schedule.endMinutes, onCommit: clampGoal)
                    Text("Drag the arc or a handle.").font(WP.font(12)).foregroundStyle(WP.caption)
                }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel("Work days")
                        dayChips
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Work days")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            timeField("Start", $schedule.startMinutes, other: schedule.endMinutes)
                            timeField("End", $schedule.endMinutes, other: schedule.startMinutes)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(WP.textBlue)
                                .accessibilityHidden(true)
                            Text(OvertimeChoice.hoursRule(rule)).font(WP.font(12)).foregroundStyle(WP.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    goalSlider
                }
            }
            .wpCard(padding: 16, strong: true)
            .wpRise(2)
        }
    }

    /// The work-day buttons of this step: 44 pt high, with the check mark above the name.
    /// (`DayChips` puts the check mark beside the name; seven of those do not fit in this column.)
    private var dayChips: some View {
        HStack(spacing: 4) {
            ForEach((0..<7).map { (model.settings.firstWeekday - 1 + $0) % 7 + 1 }, id: \.self) { day in
                let on = schedule.days.contains(day)
                Button {
                    // At least one work day stays selected.
                    if !on { schedule.days.insert(day) } else if schedule.days.count > 1 { schedule.days.remove(day) }
                } label: {
                    VStack(spacing: 1) {
                        if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)) }
                        Text(Calendar.current.shortWeekdaySymbols[day - 1]).font(WP.font(12, on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Color.white : WP.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(on ? WP.cobalt : WP.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? WP.cobalt : WP.border))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// Start or End as a time field. Start and End must differ.
    private func timeField(_ label: String, _ minutes: Binding<Int>, other: Int) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { value in
                let c = Calendar.current.dateComponents([.hour, .minute], from: value)
                let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                guard m != other else { return }
                minutes.wrappedValue = m
                clampGoal()
            })
        return VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            HStack(spacing: 0) {
                WPDateField(selection: date, elements: .hourMinute, size: 15, weight: .semibold).accessibilityLabel(label)
                Spacer(minLength: 0)
            }
            .wpField(height: 40, radius: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var goalSlider: some View {
        let length = schedule.lengthMinutes
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                FieldLabel("Daily goal")
                Spacer()
                Text(Fmt.minutes(shownGoal)).font(WP.font(15, .bold)).monospacedDigit().foregroundStyle(WP.ink)
            }
            WPSlider(value: Binding(get: { shownGoal }, set: { goal = $0 }), range: 30...goalMax, step: 30,
                     label: "Daily goal", valueText: Fmt.minutes(shownGoal))
            Text(OvertimeChoice.goalNote(goal: shownGoal, hours: length, days: schedule.days.count))
                .font(WP.font(12)).monospacedDigit().foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The goal is at most the length of the work hours, in steps of 30 minutes.
    private var goalMax: Int { max(30, schedule.lengthMinutes / 30 * 30) }
    private var shownGoal: Int { min(max(30, goal), goalMax) }
    private func clampGoal() { goal = shownGoal }

    // MARK: - Step 3: work applications

    private var applications: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Select your work applications",
                    "In the Work profile, time in these applications counts as work. You can change this later in Apps.")
                .wpRise(0)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in appRow(app) }
                }
            }
            // A short list does not leave an empty card. A long list shows half of its fifth row: there is more to scroll to.
            .frame(maxHeight: min(CGFloat(apps.count), 4.5) * Self.rowHeight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .wpCard(padding: 0, strong: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Work applications")
            .wpRise(1)
            Note(text: "WorkPulse does not read tabs or URLs. If a browser counts as work, all time in the browser counts in the Work profile.")
                .wpRise(2)
        }
    }

    /// One application with its switch. The words Work and Not work say the state (`WPSwitchStyle` says On and Off).
    private func appRow(_ app: AppRow) -> some View {
        let on = ticked.contains(app.id)
        let toggle = { if on { _ = ticked.remove(app.id) } else { _ = ticked.insert(app.id) } }
        return HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 34, height: 34).accessibilityHidden(true)
            } else {
                AppTile(name: app.name, size: 34)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(WP.font(14, .semibold)).foregroundStyle(WP.ink).lineLimit(1)
                Text(Browsers.isBrowser(app.id) ? "Browser" : app.running ? "Open now" : "Used before")
                    .font(WP.font(12)).foregroundStyle(WP.caption)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(on ? "Work" : "Not work").font(WP.font(13, .semibold)).foregroundStyle(WP.secondary)
                    .frame(minWidth: 62, alignment: .trailing).accessibilityHidden(true)
                WPSwitch(isOn: Binding(get: { on }, set: { _ in toggle() }))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .overlay(alignment: .top) { if app.id != apps.first?.id { line } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "Work" : "Not work")
        .accessibilityAction(.default, toggle)
    }

    /// The running applications and the installed applications that WorkPulse saw before, without WorkPulse.
    /// Only applications that already have the Work category start as work: WorkPulse makes no guess.
    private func load() {
        guard apps.isEmpty else { return }
        if model.settings.schedule.isUsable {
            schedule = model.settings.schedule
        } else if let days = Goals.config(on: .today(), projectID: nil, in: model.goals)?.workingDays, !days.isEmpty {
            // An earlier version stored work days with the goals: start from those days.
            schedule.days = days
        }
        // The goal can never be longer than the work hours.
        goal = min(model.dailyGoalMinutes ?? goal, max(30, schedule.lengthMinutes / 30 * 30))
        rule = model.overtimeRule
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
        return VStack(alignment: .leading, spacing: 18) {
            heading("You are ready", "You can change all settings later.").wpRise(0)
            VStack(spacing: 0) {
                recap("clock", "Work day",
                      "\(Self.daysText(schedule.days, firstWeekday: model.settings.firstWeekday).capitalizedFirst), \(Fmt.time(minutes: schedule.startMinutes)) to \(Fmt.time(minutes: schedule.endMinutes))\(schedule.endMinutes < schedule.startMinutes ? ", next day" : ""). \(rule == .flexible ? "Flexible" : "Fixed hours") overtime")
                line
                recap("square.grid.2x2", "Work applications",
                      work.isEmpty ? "None. You can add them later in Apps." : work.map(\.name).joined(separator: ", "))
                line
                recap("target", "Daily goal", rule == .flexible
                      ? "\(Fmt.minutes(shownGoal)) for each work day. Weekly goal \(Fmt.minutes(shownGoal * schedule.days.count))."
                      : "\(Fmt.minutes(shownGoal)) of work for each work day")
            }
            .wpCard(padding: 0, strong: true)
            .wpRise(1)
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Launch at login").font(WP.font(14, .semibold)).foregroundStyle(WP.ink)
                    Text("WorkPulse starts when you log in to this Mac.").font(WP.font(13)).foregroundStyle(WP.secondary)
                }
            }
            .toggleStyle(WPSwitchStyle())
            .padding(.horizontal, 16).padding(.vertical, 14)
            .wpCard(padding: 0, strong: true)
            .wpRise(2)
        }
    }

    private func recap(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            tile(symbol)
            VStack(alignment: .leading, spacing: 3) {
                FieldLabel(label)
                // ponytail: a long list of applications stops after three lines; the Apps screen shows all of them.
                Text(value).font(WP.font(14, .semibold)).monospacedDigit().foregroundStyle(WP.ink).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// "Mon to Fri" for three or more days in a row, "each day" for all seven, else "Mon, Wed".
    /// Days are 1 = Sunday … 7 = Saturday, shown in the order of the user's week.
    static func daysText(_ days: Set<Int>, firstWeekday: Int) -> String {
        let order = (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
        let on = order.indices.filter { days.contains(order[$0]) }
        let names = on.map { Calendar.current.shortWeekdaySymbols[order[$0] - 1] }
        guard let first = on.first, let last = on.last else { return "None" }
        if on.count == 7 { return "each day" }
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
        model.finishOnboarding(schedule: schedule, goalMinutes: shownGoal, overtime: rule,
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

private extension String {
    /// "Each day" at the start of a sentence; the other words keep their case.
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
