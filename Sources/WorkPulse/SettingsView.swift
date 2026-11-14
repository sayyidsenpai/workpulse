import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkPulseCore

/// How WorkPulse behaves: tracking, AI agents, sounds, compensation and the stored data.
/// Work hours, work days and the daily goal are on the Work screen.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var amount: Double?
    @State private var currency = Locale.current.currency?.identifier ?? "USD"
    @State private var month = SettingsView.gregorian.component(.month, from: Date())
    @State private var year = SettingsView.gregorian.component(.year, from: Date())
    @State private var lastBackup: String?
    @State private var confirmingHistory = false
    @State private var confirmingEverything = false
    @State private var setup: AgentInfo?

    /// `LocalDay` counts in the Gregorian calendar, so the month and year menus do too.
    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        return calendar
    }()

    var body: some View {
        // 1046 pt: the content width of the largest window in the design.
        Screen(maxWidth: 1046) {
            ScreenHeader(title: "Settings", subtitle: "")
            ViewThatFits(in: .horizontal) {
                // Two columns from 696 pt (the ideal width); below that they stack. The columns
                // have one height: the last card of the shorter column grows to the common end.
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { tracking; general; data }.frame(minWidth: 340, idealWidth: 340, maxWidth: .infinity)
                    VStack(spacing: 16) { agents; sounds; compensation }.frame(minWidth: 340, idealWidth: 340, maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 16) { tracking; general; data; agents; sounds; compensation }
            }
            deleteData
            support
        }
        .onAppear { model.refreshLoginItem() }
        .sheet(item: $setup) { AgentSetupSheet(tool: $0.tool).environment(model) }
        .confirmationDialog("Delete all recorded activity?", isPresented: $confirmingHistory) {
            Button("Delete Activity History", role: .destructive) { model.deleteHistory() }
        } message: {
            Text("This removes all sessions permanently. Rules, goals, settings, and backups stay.")
        }
        .confirmationDialog("Delete everything WorkPulse has stored?", isPresented: $confirmingEverything) {
            Button("Delete Everything", role: .destructive) { model.deleteEverything() }
        } message: {
            Text("This removes sessions, rules, categories, goals, compensation, settings, and all backups permanently. You cannot undo this.")
        }
    }

    // MARK: - Cards

    private var tracking: some View {
        card(1, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle("Tracking")
                caption("The Personal profile counts no work time. These settings apply to the Work profile.")
            }
            row("Work hours", sub: workHours) {
                Button("Change in Work…") { withAnimation(.easeOut(duration: 0.15)) { model.tab = .work } }
                    .buttonStyle(WPButtonStyle())
            }
            Toggle("Tell me when work hours start", isOn: model.binding(\.notifyWorkStart)).toggleStyle(WPSwitchStyle()).divided()
            Toggle("Tell me when work hours end", isOn: model.binding(\.notifyWorkEnd)).toggleStyle(WPSwitchStyle()).divided()
            row("After work hours, return to Personal when idle for") {
                WPMenu("After work hours, return to Personal when idle for", selection: model.binding(\.returnIdleMinutes),
                       options: choices([10, 15, 30, 60]) { "\($0) min" })
                    .frame(width: 120)
            }
            .divided()
            row("Pause when idle for") {
                WPMenu("Pause when idle for", selection: model.binding(\.idleThreshold),
                       options: choices([60, 120, 180, 300, 600, 900, 1800]) { "\($0 / 60) min" })
                    .frame(width: 120)
            }
            .divided()
            caption("Idle time starts at your last keyboard or mouse input. Screen lock and sleep pause tracking immediately.")
        }
    }

    private var general: some View {
        card(2) {
            SectionTitle("General")
            row("Appearance") {
                WPMenu("Appearance", selection: model.binding(\.theme),
                       options: [(.system, "System"), (.light, "Light"), (.dark, "Dark")])
                    .frame(width: 190)
            }
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(WPSwitchStyle()).divided()
            if let note = model.loginItemNote { Note(tone: .warn, text: note) }
            row("Menu bar shows") {
                WPMenu("Menu bar shows", selection: model.binding(\.menuBarDisplay),
                       options: [(.iconOnly, "Icon only"), (.today, "Today's work time"), (.session, "Current session")])
                    .frame(width: 190)
            }
            .divided()
            row("Week starts on") {
                WPMenu("Week starts on", selection: model.binding(\.firstWeekday),
                       options: choices(Array(1...7)) { Calendar.current.weekdaySymbols[$0 - 1] })
                    .frame(width: 190)
            }
            .divided()
        }
    }

    private var data: some View {
        card(3, fills: true) {
            SectionTitle("Data and privacy")
            Note(tone: .good, text: "All data stays on this Mac. WorkPulse has no account and no network connection. It does not record keys, screen content, tabs, or URLs.")
            row("Location", sub: model.store.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "In memory (not saved)") {
                if let directory = model.store.directory {
                    Button("Show in Finder") { NSWorkspace.shared.open(directory) }.buttonStyle(WPButtonStyle())
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                row("Backups") {
                    HStack(spacing: 8) {
                        Button("Back Up Now") { lastBackup = model.backupNow() }.buttonStyle(WPButtonStyle())
                        Button("Restore…", action: restore).buttonStyle(WPButtonStyle())
                    }
                }
                // The result of Back Up Now shows here; the design has no place for it.
                caption(lastBackup.map { "Saved \($0)" } ?? "\(model.store.backups().count) kept. WorkPulse makes one backup each day.")
                    .textSelection(.enabled)
            }
            .divided()
        }
    }

    private var agents: some View {
        card(4, spacing: 14) {
            SectionTitle("AI agents")
            // All rows have the same form: one line each when every row fits, else two lines each.
            ViewThatFits(in: .horizontal) {
                agentList(oneLine: true)
                agentList(oneLine: false)
            }
            .background(WP.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agents")
            if !model.agentConnected { Note(text: "No agent is connected. The setting below has no effect now.") }
            Toggle("Count agent work as my work", isOn: model.binding(\.countAgentWork)).toggleStyle(WPSwitchStyle())
            row("Assume the agent stopped after no signal for") {
                WPMenu("Assume the agent stopped after no signal for", selection: model.binding(\.agentQuietMinutes),
                       options: choices([5, 15, 30, 60]) { "\($0) min" })
                    .frame(width: 120)
                    .disabled(!model.settings.countAgentWork)
            }
            .divided()
            caption("While a connected agent works on a task, the time counts as work. An agent is connected after WorkPulse receives the first signal from its hook. WorkPulse reads only this signal. It does not read prompts or output.")
        }
    }

    private func agentList(oneLine: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(model.agents) { agent in
                if agent.id != model.agents.first?.id { line }
                agentRow(agent, oneLine: oneLine).padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
    }

    /// Name and last signal on the left, status and button on the right. On two lines, the
    /// status is below the name and the button stays at the right edge.
    @ViewBuilder
    private func agentRow(_ agent: AgentInfo, oneLine: Bool) -> some View {
        let name = HStack(spacing: 10) {
            AppTile(name: agent.name, symbol: "terminal", size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.name).font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
                Text(agent.lastSignal.map { "Last signal: \(AgentSetupSheet.signalTime($0))" }
                     ?? (agent.hookInstalled ? "Hooks added. No signal received." : "No signal received"))
                    .font(WP.font(12)).monospacedDigit().foregroundStyle(WP.caption)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        let status = HStack(spacing: 6) {
            if agent.connected {
                CheckBadge()
                Text("Connected").font(WP.font(13, .semibold)).foregroundStyle(WP.greenInk)
            } else {
                Image(systemName: "circle.dashed").font(.system(size: 15, weight: .semibold)).frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text("Not connected").font(WP.font(13, .semibold))
            }
        }
        .foregroundStyle(WP.secondary)
        .fixedSize()
        .accessibilityElement(children: .combine)
        // Also for a connected agent: the sheet is where the hooks can be removed again.
        let button = Button("Setup steps…") { setup = agent }.buttonStyle(WPButtonStyle())
            .accessibilityLabel("Setup steps for \(agent.name)")
        if oneLine {
            HStack(spacing: 10) { name.fixedSize(); Spacer(minLength: 2); status; button }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                name
                HStack(spacing: 10) { status; Spacer(minLength: 0); button }.padding(.leading, 38)   // under the name
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sounds: some View {
        let label = Text("Play a sound").font(WP.font(13, .medium)).foregroundStyle(WP.ink)
        let menu = WPMenu("Play a sound", selection: model.binding(\.sounds),
                          options: [(.off, "Off"), (.goalAndHours, "Goal reached and end of work hours"), (.all, "All events, with tracking controls")])
        // The label is 8 pt wide and the style adds 12 pt on each side: a 32 pt square.
        let sample = Button { Sounds.play(.goal) } label: { Image(systemName: "speaker.wave.2").frame(width: 8) }
            .buttonStyle(WPButtonStyle())
            .accessibilityLabel("Play a sample of the goal sound")
            .help("Play a sample of the goal sound")
        return card(5) {
            SectionTitle("Sounds")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { label; Spacer(minLength: 4); menu.frame(width: 290); sample }
                VStack(alignment: .leading, spacing: 6) { label; HStack(spacing: 8) { menu; sample } }
            }
            caption("Tracking controls are Start work, Pause, Resume, and End work. Sounds use the system volume. Each sound also has a visible change.")
        }
    }

    private var compensation: some View {
        card(6, fills: true) {
            SectionTitle("Compensation (optional)")
            ForEach(model.pay.reversed()) { entry in
                let from = Fmt.day(entry.effectiveFrom, "MMMMyyyy")
                row("From \(from)", sub: entry.monthlyAmount > 0
                    ? "\(entry.monthlyAmount.formatted(.currency(code: entry.currency))) per month" : "No compensation") {
                    Button { model.edit { try model.store.deleteCompensation(entry.id) } } label: { Image(systemName: "trash").frame(width: 8) }
                        .buttonStyle(WPButtonStyle(kind: .plain, text: WP.red))
                        .accessibilityLabel("Delete the compensation from \(from)")
                        .help("Delete")
                }
            }
            // One line in a wide card. In a narrow card the second line fills the width, so the
            // fields and the Add button keep one right edge.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 8) { amountField.frame(minWidth: 130); currencyMenu; effectiveFrom(monthWidth: 132); addButton }
                VStack(spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) { amountField; currencyMenu }
                    HStack(alignment: .bottom, spacing: 8) { effectiveFrom(monthWidth: nil); addButton }
                }
            }
            caption("WorkPulse uses this amount only to show an hourly rate in Reports. An amount of 0 stops it. The data stays on this Mac.")
        }
    }

    private var amountField: some View {
        labeled("Monthly amount") {
            TextField("Monthly amount", value: $amount, format: .number, prompt: Text(""))
                .textFieldStyle(.plain).font(WP.font(13)).monospacedDigit().foregroundStyle(WP.ink)
                .wpField()
        }
    }

    private var currencyMenu: some View {
        labeled("Currency") {
            WPMenu("Currency", selection: $currency, options: choices(Locale.commonISOCurrencyCodes) { $0 }).frame(width: 92)
        }
        .fixedSize()
    }

    private func effectiveFrom(monthWidth: CGFloat?) -> some View {
        labeled("Effective from") {
            HStack(spacing: 6) {
                WPMenu("Effective from, month", selection: $month,
                       options: choices(Array(1...12)) { Self.gregorian.standaloneMonthSymbols[$0 - 1] })
                    .frame(width: monthWidth)
                WPMenu("Effective from, year", selection: $year, options: choices(Array(yearRange)) { String($0) }).frame(width: 88)
            }
        }
    }

    private var addButton: some View {
        Button("Add") {
            let entry = Compensation(effectiveFrom: LocalDay(year: year, month: month, day: 1),
                                     monthlyAmount: max(0, amount ?? 0), currency: currency)
            model.edit { try model.store.saveCompensation(entry) }
            amount = nil
        }
        .buttonStyle(WPButtonStyle())
        .disabled(amount == nil)
    }

    /// Ten years back, for a compensation that started before WorkPulse, to next year.
    private var yearRange: ClosedRange<Int> {
        let now = Self.gregorian.component(.year, from: Date())
        return (now - 10)...(now + 1)
    }

    /// One quiet line at the end of the screen. The button only opens the browser; WorkPulse
    /// itself makes no network connection.
    private var support: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { supportText; Spacer(minLength: 0); sponsorButton }
            VStack(alignment: .leading, spacing: 10) { supportText; sponsorButton }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wpCard()
    }

    private var supportText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("WorkPulse is free and open source.").font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
            Text("If it saves you time, you can buy me a coffee.").font(WP.font(12)).foregroundStyle(WP.secondary)
        }
    }

    private var sponsorButton: some View {
        Link(destination: URL(string: "https://github.com/sponsors/sayyidsenpai")!) {
            Label("Sponsor on GitHub", systemImage: "heart")
        }
        .buttonStyle(WPButtonStyle())
        .help("Opens github.com/sponsors/sayyidsenpai in your browser")
    }

    private var deleteData: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 15, weight: .semibold)).accessibilityHidden(true)
                Text("Delete data").font(WP.font(15, .bold)).accessibilityAddTraits(.isHeader)
            }
            .foregroundStyle(WP.red)
            deleteRow("Delete activity history", "This removes all sessions permanently. Rules, goals, settings, and backups stay.",
                      button: "Delete Activity History…") { confirmingHistory = true }
            deleteRow("Delete everything", "This removes sessions, rules, categories, goals, compensation, settings, and all backups permanently. You cannot undo this.",
                      button: "Delete Everything…") { confirmingEverything = true }
                .divided(WP.red.opacity(0.3))
            Text("Each button opens a confirmation first.").font(WP.font(12)).foregroundStyle(WP.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // A light red over the card surface: the design's delete card.
        .background(WP.red.opacity(0.05), in: shape)
        .background(WP.cardStrong, in: shape)
        .overlay(shape.strokeBorder(WP.red))
    }

    private func deleteRow(_ title: String, _ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
                Text(text).font(WP.font(13)).foregroundStyle(WP.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: action) { Label(button, systemImage: "trash").labelStyle(.titleAndIcon) }
                .buttonStyle(WPButtonStyle(fill: WP.field, text: WP.red))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WP.red).allowsHitTesting(false))
        }
    }

    // MARK: - Parts

    /// `fills`: the card grows to the end of its column (the last card of a column).
    private func card<Content: View>(_ index: Int, spacing: CGFloat = 12, fills: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .wpCard(strong: true)
    }

    private var line: some View { Rectangle().fill(WP.hairline).frame(height: 1).accessibilityHidden(true) }

    private func caption(_ text: String) -> some View {
        Text(text).font(WP.font(12)).foregroundStyle(WP.caption).fixedSize(horizontal: false, vertical: true)
    }

    /// Menu options from values and a title for each value.
    private func choices<Value>(_ values: [Value], _ title: (Value) -> String) -> [(value: Value, title: String)] {
        values.map { ($0, title($0)) }
    }

    /// A label with its control at the right edge. The label takes more lines in a narrow card.
    private func row<Control: View>(_ label: String, sub: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(WP.font(13, .medium)).foregroundStyle(WP.ink)
                if let sub {
                    Text(sub).font(WP.font(12)).monospacedDigit().foregroundStyle(WP.caption).textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()   // the label gives way, never the control
        }
    }

    private func labeled<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            control()
        }
    }

    /// "Mon to Fri · 08.00 to 16.00", from the work hours on the Work screen.
    private var workHours: String {
        let schedule = model.settings.schedule
        guard schedule.isUsable else { return "Work hours are off." }
        let days = (0..<7).map { (model.settings.firstWeekday - 1 + $0) % 7 + 1 }.filter(schedule.days.contains)
        let names = days.map { Calendar.current.shortWeekdaySymbols[$0 - 1] }
        let inSequence = days.count > 2 && zip(days, days.dropFirst()).allSatisfy { $1 == $0 % 7 + 1 }
        let text = days.count == 7 ? "Every day" : inSequence ? "\(names[0]) to \(names[names.count - 1])" : names.joined(separator: ", ")
        return "\(text) · \(Fmt.time(minutes: schedule.startMinutes)) to \(Fmt.time(minutes: schedule.endMinutes))"
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.directoryURL = model.store.directory?.appendingPathComponent("Backups")
        panel.message = "Choose a backup to restore. The current database is kept next to it as pre-restore-….sqlite."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.restore(from: url)
    }
}

private extension View {
    /// A row below a divider line: 12 pt between the line and the row.
    func divided(_ color: Color = WP.hairline) -> some View {
        padding(.top, 12).overlay(alignment: .top) { Rectangle().fill(color).frame(height: 1).accessibilityHidden(true) }
    }
}
