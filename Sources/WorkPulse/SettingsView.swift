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
        Screen {
            ScreenHeader(title: "Settings", subtitle: "These settings control tracking, AI agents, sounds, and your data.")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    // The ideal width makes the two columns fit from 696 pt; below that they stack.
                    VStack(spacing: 16) { tracking; general; data }.frame(minWidth: 340, idealWidth: 340, maxWidth: .infinity)
                    VStack(spacing: 16) { agents; sounds; compensation }.frame(minWidth: 340, idealWidth: 340, maxWidth: .infinity)
                }
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
            row("Work hours", sub: workHours, wraps: true) {
                Button("Change in Work…") { withAnimation(.easeOut(duration: 0.15)) { model.tab = .work } }
                    .buttonStyle(WPButtonStyle())
            }
            line
            Toggle("Tell me when work hours end", isOn: model.binding(\.notifyWorkEnd)).toggleStyle(WPSwitchStyle())
            line
            row("After work hours, return to Personal when idle for") {
                ChoiceMenu(label: "After work hours, return to Personal when idle for", selection: model.binding(\.returnIdleMinutes),
                           options: [10, 15, 30, 60], width: 120) { "\($0) min" }
            }
            line
            row("Pause when idle for") {
                ChoiceMenu(label: "Pause when idle for", selection: model.binding(\.idleThreshold),
                           options: [60, 120, 180, 300, 600, 900, 1800], width: 120) { "\($0 / 60) min" }
            }
            caption("Idle time starts at your last keyboard or mouse input. Screen lock and sleep pause tracking immediately.")
        }
    }

    private var general: some View {
        card(2) {
            SectionTitle("General")
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(WPSwitchStyle())
            if let note = model.loginItemNote { Note(tone: .warn, text: note) }
            line
            row("Menu bar shows") {
                ChoiceMenu(label: "Menu bar shows", selection: model.binding(\.menuBarDisplay), options: MenuBarDisplay.allCases, width: 170) {
                    switch $0 {
                    case .iconOnly: "Icon only"
                    case .today: "Today's work time"
                    case .session: "Current session"
                    }
                }
            }
            line
            row("Week starts on") {
                ChoiceMenu(label: "Week starts on", selection: model.binding(\.firstWeekday), options: Array(1...7), width: 170) {
                    Calendar.current.weekdaySymbols[$0 - 1]
                }
            }
        }
    }

    private var data: some View {
        card(3) {
            SectionTitle("Data and privacy")
            Note(tone: .good, text: "All data stays on this Mac. WorkPulse has no account and no network connection. It does not record keys, screen content, tabs, or URLs.")
            row("Location", sub: model.store.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "In memory (not saved)", wraps: true) {
                if let directory = model.store.directory {
                    Button("Show in Finder") { NSWorkspace.shared.open(directory) }.buttonStyle(WPButtonStyle())
                }
            }
            line
            row("Backups", sub: lastBackup.map { "Saved \($0)" } ?? "\(model.store.backups().count) kept. WorkPulse makes one backup each day.", wraps: true) {
                HStack(spacing: 8) {
                    Button("Back Up Now") { lastBackup = model.backupNow() }.buttonStyle(WPButtonStyle())
                    Button("Restore…", action: restore).buttonStyle(WPButtonStyle())
                }
            }
        }
    }

    private var agents: some View {
        card(4, spacing: 14) {
            SectionTitle("AI agents")
            VStack(spacing: 0) {
                ForEach(model.agents) { agent in
                    if agent.id != model.agents.first?.id { line }
                    agentRow(agent).padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            .background(WP.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agents")
            if !model.agentConnected { Note(text: "No agent is connected. The setting below has no effect now.") }
            Toggle("Count agent work as my work", isOn: model.binding(\.countAgentWork)).toggleStyle(WPSwitchStyle())
            line
            row("Assume the agent stopped after no signal for") {
                ChoiceMenu(label: "Assume the agent stopped after no signal for", selection: model.binding(\.agentQuietMinutes),
                           options: [5, 15, 30, 60], width: 120) { "\($0) min" }
                    .disabled(!model.settings.countAgentWork)
            }
            caption("While a connected agent works on a task, the time counts as work. An agent is connected after WorkPulse receives the first signal from its hook. WorkPulse reads only this signal. It does not read prompts or output.")
        }
    }

    private func agentRow(_ agent: AgentInfo) -> some View {
        let name = HStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(WP.navy, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(agent.name).font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
                Text(agent.lastSignal.map { "Last signal: \(AgentSetupSheet.signalTime($0))" }
                     ?? (agent.hookInstalled ? "Hooks added. No signal received." : "No signal received"))
                    .font(WP.font(12)).monospacedDigit().foregroundStyle(WP.caption)
            }
        }
        let state = HStack(spacing: 10) {
            if agent.connected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(WP.green)
                    Text("Connected").font(WP.font(13, .semibold)).foregroundStyle(WP.greenInk)
                }
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "circle.dashed")
                    Text("Not connected").font(WP.font(13, .semibold))
                }
                .foregroundStyle(WP.secondary)
                .accessibilityElement(children: .combine)
            }
            // Also for a connected agent: the sheet is where the hooks can be removed again.
            Button("Setup steps…") { setup = agent }.buttonStyle(WPButtonStyle())
                .accessibilityLabel("Setup steps for \(agent.name)")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { name; Spacer(minLength: 0); state }
            VStack(alignment: .leading, spacing: 8) { name; state }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sounds: some View {
        card(5) {
            SectionTitle("Sounds")
            VStack(alignment: .leading, spacing: 6) {
                Text("Play a sound").font(WP.font(13, .medium)).foregroundStyle(WP.ink)
                HStack(spacing: 8) {
                    ChoiceMenu(label: "Play a sound", selection: model.binding(\.sounds), options: SoundMode.allCases) {
                        switch $0 {
                        case .off: "Off"
                        case .goalAndHours: "Goal reached and end of work hours"
                        case .all: "All events, with tracking controls"
                        }
                    }
                    Button { Sounds.play(.goal) } label: { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(WPButtonStyle())
                        .accessibilityLabel("Play a sample of the goal sound")
                        .help("Play a sample of the goal sound")
                }
            }
            caption("Tracking controls are Start work, Pause, Resume, and End work. Sounds use the system volume. Each sound also has a visible change.")
        }
    }

    private var compensation: some View {
        card(6) {
            SectionTitle("Compensation (optional)")
            ForEach(model.pay.reversed()) { entry in
                let from = Fmt.day(entry.effectiveFrom, "MMMMyyyy")
                row("From \(from)", sub: entry.monthlyAmount > 0
                    ? "\(entry.monthlyAmount.formatted(.currency(code: entry.currency))) per month" : "No compensation") {
                    Button { model.edit { try model.store.deleteCompensation(entry.id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(WPButtonStyle(kind: .plain, text: WP.red))
                        .accessibilityLabel("Delete the compensation from \(from)")
                        .help("Delete")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                labeled("Monthly amount") {
                    TextField("Monthly amount", value: $amount, format: .number, prompt: Text("Amount"))
                        .textFieldStyle(.plain).font(WP.font(13)).monospacedDigit().foregroundStyle(WP.ink)
                        .wpField()
                }
                labeled("Currency") {
                    ChoiceMenu(label: "Currency", selection: $currency, options: Locale.commonISOCurrencyCodes, width: 92) { $0 }
                }
                .fixedSize()
            }
            HStack(alignment: .bottom, spacing: 8) {
                labeled("Effective from") {
                    HStack(spacing: 6) {
                        ChoiceMenu(label: "Effective from, month", selection: $month, options: Array(1...12)) {
                            Self.gregorian.standaloneMonthSymbols[$0 - 1]
                        }
                        ChoiceMenu(label: "Effective from, year", selection: $year, options: Array(yearRange), width: 88) { String($0) }
                    }
                }
                Button("Add") {
                    let entry = Compensation(effectiveFrom: LocalDay(year: year, month: month, day: 1),
                                             monthlyAmount: max(0, amount ?? 0), currency: currency)
                    model.edit { try model.store.saveCompensation(entry) }
                    amount = nil
                }
                .buttonStyle(WPButtonStyle())
                .disabled(amount == nil)
            }
            caption("WorkPulse uses this amount only to show an hourly rate in Reports. An amount of 0 stops it. The data stays on this Mac.")
        }
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
        .wpCard(padding: 14)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 15, weight: .semibold)).foregroundStyle(WP.red)
                    .accessibilityHidden(true)
                SectionTitle("Delete data")
            }
            deleteRow("Delete activity history", "This removes all sessions permanently. Rules, goals, settings, and backups stay.",
                      button: "Delete Activity History…") { confirmingHistory = true }
            line
            deleteRow("Delete everything", "This removes sessions, rules, categories, goals, compensation, settings, and all backups permanently. You cannot undo this.",
                      button: "Delete Everything…") { confirmingEverything = true }
            Text("Each button opens a confirmation first.").font(WP.font(12)).foregroundStyle(WP.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wpCard(strong: true)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WP.red))
        .wpRise(7)
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

    private func card<Content: View>(_ index: Int, spacing: CGFloat = 12, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .wpCard(strong: true)
            .wpRise(index)
    }

    private var line: some View { Rectangle().fill(WP.hairline).frame(height: 1).accessibilityHidden(true) }

    private func caption(_ text: String) -> some View {
        Text(text).font(WP.font(12)).foregroundStyle(WP.caption).fixedSize(horizontal: false, vertical: true)
    }

    /// A label with its control on the right. With `wraps`, the control moves below the label
    /// when the two do not fit on one line; without it, the label takes more lines.
    @ViewBuilder
    private func row<Control: View>(_ label: String, sub: String? = nil, wraps: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        let text = VStack(alignment: .leading, spacing: 0) {
            Text(label).font(WP.font(13, .medium)).foregroundStyle(WP.ink)
            if let sub {
                Text(sub).font(WP.font(12)).monospacedDigit().foregroundStyle(WP.caption).textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        let control = control()
        if wraps {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { text; Spacer(minLength: 0); control }
                VStack(alignment: .leading, spacing: 8) { text; control }.frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(spacing: 12) { text.frame(maxWidth: .infinity, alignment: .leading); control }
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

/// A menu of fixed choices in the standard field outline. The whole field opens the menu.
/// Without `width` it fills the space it gets.
private struct ChoiceMenu<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    var width: CGFloat?
    let title: (Value) -> String
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { Text(title($0)).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(title(selection)).font(WP.font(13, .medium)).foregroundStyle(WP.ink).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(WP.caption)
            }
            .wpField()
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(width: width)
        .opacity(enabled ? 1 : 0.6)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }
}
