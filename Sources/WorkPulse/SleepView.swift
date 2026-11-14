import SwiftUI
import WorkPulseCore

/// Optional bedtime reminders. A reminder is a macOS notification: it never starts, stops or changes tracking.
struct SleepView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var custom = false
    @State private var moonIn = false

    private var settings: SleepSettings { model.settings.sleep }
    private var off: Bool { !settings.enabled }

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
        Screen {
            ScreenHeader(title: "Sleep", subtitle: "A reminder is only a notification. It does not stop a work session, change tracked time, or close an application.")
            TimelineView(.everyMinute) { context in hero(context.date) }
            // Two columns of 340 pt or more, with the height of the taller one; else one below the other.
            SideBySide(leading: 340, equalHeights: true) {
                scheduleCard
                side
            }
        }
        .animation(.easeInOut(duration: 0.25), value: off)
        .onAppear { model.rescheduleReminders(requestPermission: false) }
        // The user can change the permission in System Settings: read it again on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.rescheduleReminders(requestPermission: false)
        }
    }

    // MARK: - Next reminder

    private func hero(_ now: Date) -> some View {
        let next = SleepSchedule.nextFire(after: now, settings: settings)
        let summary = HStack(spacing: 16) {
            Image(systemName: "moon").font(.system(size: 21, weight: .semibold)).foregroundStyle(WP.navy)
                .frame(width: 56, height: 56)
                .background(WP.onNavy, in: Circle())
                .rotationEffect(.degrees(moonIn || reduceMotion ? 0 : -18))
                .scaleEffect(moonIn || reduceMotion ? 1 : 0.8)
                .onAppear { withAnimation(WP.spring.delay(0.2)) { moonIn = true } }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next reminder").font(WP.font(12, .medium)).foregroundStyle(WP.onNavy)
                Text(next.map { Fmt.time($0) } ?? (off ? "Off" : "None"))
                    .font(WP.font(44, .bold)).tracking(-0.9).monospacedDigit().foregroundStyle(.white)
                    .frame(height: 44)   // line height 1, as in the design
                Text(detail(next)).font(WP.font(13)).monospacedDigit().foregroundStyle(WP.onNavy)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        let toggle = Toggle("Remind me to go to sleep", isOn: sleep.enabled).toggleStyle(HeroSwitchStyle())
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { summary; Spacer(minLength: 0); toggle }
            VStack(alignment: .leading, spacing: 16) { summary; toggle }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WP.navy, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {   // the light edge at the top of the card
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2)))
                .allowsHitTesting(false)
        }
        .shadow(color: WP.navy.opacity(0.35), radius: 14, y: 12)
    }

    private func detail(_ next: Date?) -> String {
        guard let next else { return off ? "WorkPulse sends no reminder." : "Select one day or more." }
        let calendar = Calendar.current
        let day = calendar.isDateInToday(next) ? "Today" : calendar.isDateInTomorrow(next) ? "Tomorrow"
            : calendar.weekdaySymbols[calendar.component(.weekday, from: next) - 1]
        return settings.leadMinutes > 0
            ? "\(day) · \(settings.leadMinutes) minutes before bedtime at \(Fmt.time(minutes: settings.bedtimeMinutes))"
            : "\(day) · At bedtime"
    }

    // MARK: - Schedule

    /// The cards of the two columns end on one line: the space between the parts of a card grows from this minimum.
    private func gap(_ length: CGFloat = 14) -> some View { Spacer(minLength: length) }
    /// Shared controls dim themselves when disabled; texts and private controls use this.
    private var dim: Double { off ? 0.45 : 1 }

    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Schedule")
            gap()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Target bedtime")
                    HStack(spacing: 0) {
                        WPDateField(selection: bedtime, size: 15, weight: .semibold).accessibilityLabel("Target bedtime")
                            // The native field has its own inset: the text starts where the menu text starts, on its baseline.
                            .padding(.leading, -3).offset(y: 1.5)
                        Spacer(minLength: 0)
                    }
                    .wpField()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(dim)
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Remind me").opacity(dim)
                    WPMenu("Remind me", selection: sleep.leadMinutes, options: [0, 5, 10, 15, 30, 45, 60, 90, 120].map {
                        (value: $0, title: $0 == 0 ? "At bedtime" : "\($0) minutes before")
                    })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            gap()
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Days")
                dayModes
                if schedule.wrappedValue == 2 {
                    DayChips(days: sleep.days, firstWeekday: model.settings.firstWeekday, keepOne: true)
                }
            }
            .opacity(dim)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Days")
            gap()
            TimelineView(.everyMinute) { context in DayBar(now: context.date, settings: settings) }
                .padding(.top, 12)
                .overlay(alignment: .top) { Rectangle().fill(WP.hairline).frame(height: 1) }
                .opacity(dim)
        }
        .disabled(off)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wpCard(strong: true)
    }

    /// Every day, Weekdays or Custom. A check mark shows the selected one.
    private var dayModes: some View {
        HStack(spacing: 2) {
            ForEach(Array(["Every day", "Weekdays", "Custom"].enumerated()), id: \.offset) { index, title in
                let on = schedule.wrappedValue == index
                Button { schedule.wrappedValue = index } label: {
                    HStack(spacing: 5) {
                        if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)) }
                        Text(title).font(WP.font(13, on ? .semibold : .medium)).lineLimit(1)
                    }
                    .foregroundStyle(on ? WP.ink : WP.secondary)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(on ? WP.field : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: on ? WP.navy.opacity(0.2) : .clear, radius: 1.5, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(WP.track, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Notification and permission

    private var side: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                // The test button is the action of this card: it sits in the title line and adds no row.
                SectionTitle("Notification")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        Button("Send Test Reminder") {
                            Task {
                                await model.reminders.requestAuthorization()
                                await model.reminders.sendTest(model.settings.sleep)
                            }
                        }
                        .buttonStyle(WPButtonStyle(height: 28))
                        .disabled(!model.reminders.available)
                        .help("Shows the reminder in 2 seconds, with the sound setting below.")
                    }
                gap()
                Toggle("Play sound", isOn: sleep.sound).toggleStyle(WPSwitchStyle()).disabled(off)
                gap()
                HStack(spacing: 12) {
                    Text("Snooze for").font(WP.font(13, .medium)).foregroundStyle(WP.ink).opacity(dim)
                    Spacer(minLength: 0)
                    WPMenu("Snooze for", selection: sleep.snoozeMinutes, options: [5, 10, 15, 20, 30].map {
                        (value: $0, title: "\($0) minutes")
                    })
                    .frame(width: 150)
                }
                .disabled(off)
                .padding(.top, 12)
                .overlay(alignment: .top) { Rectangle().fill(WP.hairline).frame(height: 1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .wpCard(strong: true)
            permissionCard.layoutPriority(1)   // takes its small share of extra height first; the card above takes the rest
        }
    }

    private var permissionCard: some View {
        let state = permission
        let status = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: state.symbol).font(.system(size: 15)).foregroundStyle(state.tint).accessibilityHidden(true)
            Text(state.text).font(WP.font(13, .semibold)).foregroundStyle(state.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        return ViewThatFits(in: .horizontal) {
            if state.hint == nil {
                // As in the design: the button at the right of the status.
                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle("Permission")
                    permissionGap
                    HStack(spacing: 24) { status; Spacer(minLength: 0); permissionButton(height: 32) }
                }
            }
            // A narrow column, or a hint below the status: the button goes to the title line, as in the Notification card.
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("Permission")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) { permissionButton(height: 28) }
                permissionGap
                status
                if let hint = state.hint {
                    Text(hint).font(WP.font(12)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wpCard(strong: true)
    }

    /// Grows a little only: when the Schedule card is the taller one, the Notification card takes most of the difference.
    private var permissionGap: some View { gap(12).frame(maxHeight: 26) }

    @ViewBuilder private func permissionButton(height: CGFloat) -> some View {
        if model.reminders.available, model.notificationStatus.hasPrefix("Not requested") {
            Button("Allow Notifications…") { model.rescheduleReminders(requestPermission: true) }
                .buttonStyle(WPButtonStyle(kind: .primary, height: height))
        } else {
            Button("Notification Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(WPButtonStyle(height: height))
        }
    }

    /// The permission as an icon, a sentence and, when the user must do something, a hint.
    private var permission: (symbol: String, tint: Color, ink: Color, text: String, hint: String?) {
        // ponytail: reads the texts of `SleepReminders.status()`. Use a typed status when that function has one.
        let status = model.notificationStatus
        if !model.reminders.available {
            return ("exclamationmark.triangle.fill", WP.warnInk, WP.ink, "Notifications are not available",
                    "This copy of WorkPulse is not an application bundle. macOS cannot show its reminders.")
        }
        if status.hasPrefix("Allowed") { return ("checkmark.circle.fill", WP.green, WP.greenInk, "Notifications are allowed", nil) }
        if status.hasPrefix("Denied") {
            return ("exclamationmark.triangle.fill", WP.warnInk, WP.ink, "Notifications are not allowed",
                    "macOS does not show the reminders. Allow notifications for WorkPulse in Notification Settings.")
        }
        if status.hasPrefix("Not requested") {
            return ("questionmark.circle.fill", WP.textBlue, WP.ink, "WorkPulse did not ask for permission yet", nil)
        }
        return ("info.circle.fill", WP.textBlue, WP.ink, status, nil)
    }
}

/// The switch on the navy card: the label and the word On or Off at the left, a white outline on the track.
private struct HeroSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                configuration.label.font(WP.font(13, .semibold)).foregroundStyle(.white)
                Text(configuration.isOn ? "On" : "Off").font(WP.font(12)).foregroundStyle(WP.onNavy).accessibilityHidden(true)
            }
            WPSwitch(isOn: configuration.$isOn, width: 52, height: 30, outlined: true)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

/// Today from 00.00 to 24.00: the time now, the reminder of today and, for an evening bedtime, the time after bedtime.
private struct DayBar: View {
    let now: Date
    let settings: SleepSettings

    var body: some View {
        let calendar = Calendar.current
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let today = calendar.component(.weekday, from: now)
        let reminder = SleepSchedule.triggers(settings).first { $0.weekday == today }.map { $0.hour * 60 + $0.minute }
        // ponytail: a bedtime after midnight gets no block, because the bar shows one calendar day only.
        let bedtime = settings.enabled && settings.days.contains(today) && settings.bedtimeMinutes >= 720 ? settings.bedtimeMinutes : nil
        GeometryReader { geo in
            let width = geo.size.width
            let nowX = width * CGFloat(nowMinutes) / 1440
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        WP.track
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(WP.cobalt).frame(width: nowX)
                        if let bedtime {
                            WP.navy.overlay(Rectangle().strokeBorder(WP.border))   // the outline keeps it visible in dark appearance
                                .frame(width: width * CGFloat(1440 - bedtime) / 1440)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    if let reminder {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(WP.amberHatch).frame(width: 3, height: 18)
                            .offset(x: min(width - 3, width * CGFloat(reminder) / 1440))
                    }
                }
                .frame(width: width, height: 10)
                HStack(spacing: 8) {
                    Text("00.00").foregroundStyle(WP.secondary)
                    // "Now" stays below the end of the blue bar, but never on top of the other two labels.
                    Color.clear.frame(maxWidth: .infinity).overlay {
                        GeometryReader { slot in
                            Text("Now \(Fmt.time(minutes: nowMinutes))").fontWeight(.semibold).foregroundStyle(WP.textBlue).fixedSize()
                                .position(x: min(max(nowX - slot.frame(in: .named("day")).minX, 32), slot.size.width - 32),
                                          y: slot.size.height / 2)
                        }
                    }
                    Text(reminder.map { "Reminder \(Fmt.time(minutes: $0))" } ?? "No reminder today").fontWeight(.semibold)
                        .foregroundStyle(reminder == nil ? WP.secondary : WP.warnInk)
                }
                .font(WP.font(12)).monospacedDigit()
                .frame(height: 18)
            }
        }
        .frame(height: 34)
        .coordinateSpace(.named("day"))
        .accessibilityElement()
        .accessibilityLabel("Today: now \(Fmt.time(minutes: nowMinutes)), "
            + (reminder.map { "reminder \(Fmt.time(minutes: $0))" } ?? "no reminder today")
            + ", bedtime \(Fmt.time(minutes: settings.bedtimeMinutes))")
    }
}
