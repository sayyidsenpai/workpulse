import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkPulseCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var amount: Double?
    @State private var currency = Locale.current.currency?.identifier ?? "USD"
    @State private var effective = Date()
    @State private var lastBackup: String?
    @State private var confirmingHistory = false
    @State private var confirmingEverything = false

    var body: some View {
        Form {
            Section("Tracking") {
                Picker("Mode", selection: model.binding(\.mode)) {
                    ForEach(TrackingMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Text(modeHelp).font(.caption).foregroundStyle(.secondary)
                Picker("Pause when idle for", selection: model.binding(\.idleThreshold)) {
                    ForEach([60, 120, 180, 300, 600, 900, 1800], id: \.self) { Text("\($0 / 60) min").tag($0) }
                }
                Text("Idle time is taken back to your last keyboard or mouse input, in every mode. Screen lock and sleep pause tracking immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("AI agents") {
                Toggle("Count Claude Code and Codex work as my work", isOn: model.binding(\.countAgentWork))
                Picker("Assume the agent stopped after no signal for", selection: model.binding(\.agentQuietMinutes)) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .disabled(!model.settings.countAgentWork)
                Text("While an agent is working on a task, time counts as work even if you are idle, the screen is locked or another app is in front. Your own work in a work app keeps its own name, so nothing is counted twice. Detection relies on the agent's own hooks (prompt submitted, tool used, finished); WorkPulse sees only that an agent is working, never prompts or output. Without the hooks nothing changes. Setup is described in the README.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if let note = model.loginItemNote { Text(note).font(.caption).foregroundStyle(.orange) }
                Picker("Menu bar shows", selection: model.binding(\.menuBarDisplay)) {
                    Text("Icon only").tag(MenuBarDisplay.iconOnly)
                    Text("Today's work time").tag(MenuBarDisplay.today)
                    Text("Current session").tag(MenuBarDisplay.session)
                }
                Picker("Week starts on", selection: model.binding(\.firstWeekday)) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
            }

            Section("Compensation (optional)") {
                ForEach(model.pay.reversed()) { entry in
                    HStack {
                        Text("From \(Fmt.day(entry.effectiveFrom, "MMMMyyyy"))")
                        Spacer()
                        Text(entry.monthlyAmount > 0 ? "\(entry.monthlyAmount.formatted(.currency(code: entry.currency))) per month" : "No compensation")
                            .foregroundStyle(.secondary)
                        Button { model.edit { try model.store.deleteCompensation(entry.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Monthly amount", value: $amount, format: .number, prompt: Text("Amount"))
                    Picker("Currency", selection: $currency) {
                        ForEach(Locale.commonISOCurrencyCodes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    DatePicker("Effective from", selection: $effective, displayedComponents: .date).labelsHidden()
                    Button("Add") {
                        let entry = Compensation(effectiveFrom: LocalDay.today(effective).monthStart, monthlyAmount: max(0, amount ?? 0), currency: currency)
                        model.edit { try model.store.saveCompensation(entry) }
                        amount = nil
                    }
                    .disabled(amount == nil)
                }
                Text("Used only to show an effective hourly rate in Reports (monthly amount ÷ hours worked that month). Each entry applies from the first day of its month until the next entry; an amount of 0 ends it. Stored only on this Mac. No tax or employment assumptions are made.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.store.directory?.path ?? "In memory (not saved)").textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        if let directory = model.store.directory {
                            Button("Show in Finder") { NSWorkspace.shared.open(directory) }
                        }
                    }
                }
                LabeledContent("Backups") {
                    HStack {
                        Text(lastBackup.map { "Saved \($0)" } ?? "\(model.store.backups().count) kept · one is made automatically each day")
                            .foregroundStyle(.secondary).lineLimit(1)
                        Button("Back Up Now") { lastBackup = model.backupNow() }
                        Button("Restore…", action: restore)
                    }
                }
                LabeledContent("Delete") {
                    HStack {
                        Button("Delete Activity History…") { confirmingHistory = true }
                        Button("Delete Everything…") { confirmingEverything = true }
                    }
                }
            }

            Section("Privacy and permissions") {
                Text("""
                WorkPulse keeps everything in one database on this Mac. There is no account, no network connection, no telemetry and no analytics.

                What is recorded: which application is in front and for how long, and how long ago the keyboard or mouse was last used. What is never recorded: keystrokes, window titles, screen contents, URLs or browser tabs. Applications in the “Ignored” category leave only a duration.

                Tracking needs no special permission (no Accessibility, Screen Recording or Input Monitoring). Notifications are requested only if you turn on sleep reminders; without permission the reminders simply are not shown. “Launch at login” adds WorkPulse to Login Items, where you can remove it at any time.
                """)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItem() }
        .confirmationDialog("Delete all recorded activity?", isPresented: $confirmingHistory) {
            Button("Delete Activity History", role: .destructive) { model.deleteHistory() }
        } message: {
            Text("All sessions are permanently removed from the database. Rules, goals, settings and existing backups are kept.")
        }
        .confirmationDialog("Delete everything WorkPulse has stored?", isPresented: $confirmingEverything) {
            Button("Delete Everything", role: .destructive) { model.deleteEverything() }
        } message: {
            Text("Sessions, rules, categories, projects, goals, compensation, settings and all backups are permanently removed. This cannot be undone.")
        }
    }

    private var modeHelp: String {
        switch model.settings.mode {
        case .automatic: "Automatic: time is recorded whenever you are active and classified by each application's category."
        case .manual: "Manual: nothing is recorded until you press Start. Everything until Stop counts as work, except ignored applications."
        case .hybrid: "Hybrid: automatic tracking, plus Start/Stop work sessions that count everything as work while they run. Both share one timeline, so nothing is counted twice."
        }
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

/// Optional bedtime reminders. Independent of tracking in both directions.
struct SleepView: View {
    @Environment(AppModel.self) private var model
    @State private var custom = false

    private var sleep: Binding<SleepSettings> {
        Binding(get: { model.settings.sleep }, set: { model.setSleep($0) })
    }

    private var bedtime: Binding<Date> {
        Binding(get: {
            let minutes = model.settings.sleep.bedtimeMinutes
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            sleep.wrappedValue.bedtimeMinutes = (parts.hour ?? 23) * 60 + (parts.minute ?? 0)
        })
    }

    /// 0 = every day, 1 = weekdays, 2 = custom.
    private var schedule: Binding<Int> {
        Binding(get: {
            if custom { return 2 }
            let days = model.settings.sleep.days
            return days == Set(1...7) ? 0 : days == Set(2...6) ? 1 : 2
        }, set: { choice in
            custom = choice == 2
            if choice == 0 { sleep.wrappedValue.days = Set(1...7) }
            if choice == 1 { sleep.wrappedValue.days = Set(2...6) }
        })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Remind me to go to sleep", isOn: sleep.enabled)
                Text("A reminder is only a notification. It never stops a work session, changes tracked time or closes anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Schedule") {
                DatePicker("Target bedtime", selection: bedtime, displayedComponents: .hourAndMinute)
                Picker("Remind me", selection: sleep.leadMinutes) {
                    Text("At bedtime").tag(0)
                    ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes before").tag($0) }
                }
                Picker("Days", selection: schedule) {
                    Text("Every day").tag(0)
                    Text("Weekdays").tag(1)
                    Text("Custom").tag(2)
                }
                if schedule.wrappedValue == 2 {
                    LabeledContent("Bedtime on") {
                        WeekdayPicker(days: sleep.days, firstWeekday: model.settings.firstWeekday)
                    }
                }
                LabeledContent("Next reminder", value: nextReminder)
            }
            .disabled(!model.settings.sleep.enabled)

            Section("Notification") {
                Toggle("Play sound", isOn: sleep.sound)
                Picker("Snooze for", selection: sleep.snoozeMinutes) {
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                LabeledContent("Permission") {
                    HStack {
                        Text(model.notificationStatus).foregroundStyle(.secondary)
                        Button("Notification Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                Button("Send Test Reminder") {
                    Task {
                        await model.reminders.requestAuthorization()
                        await model.reminders.sendTest(model.settings.sleep)
                        model.rescheduleReminders(requestPermission: false)
                    }
                }
                Text("Reminders are scheduled with macOS, so they arrive even when WorkPulse is not running. Each one offers Snooze and Dismiss. If notifications are not allowed, reminders are silently skipped and nothing else is affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.rescheduleReminders(requestPermission: false) }
    }

    private var nextReminder: String {
        guard let next = SleepSchedule.nextFire(after: Date(), settings: model.settings.sleep) else {
            return model.settings.sleep.enabled ? "No days selected" : "Off"
        }
        return next.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}
