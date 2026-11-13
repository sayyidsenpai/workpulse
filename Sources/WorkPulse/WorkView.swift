import SwiftUI
import WorkPulseCore

/// When the user works and how much work they want to do each day. Changes apply at once.
struct WorkView: View {
    @Environment(AppModel.self) private var model
    @State private var schedule = WorkSchedule()
    @State private var goal = WorkDayEditor.defaultGoal

    var body: some View {
        Screen(maxWidth: 808) {
            ScreenHeader(title: "Work", subtitle: "Set when you work and how much work you want to do each day.")
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle("Work day")
                WorkDayEditor(schedule: $schedule, goal: $goal, firstWeekday: model.settings.firstWeekday,
                              goalIsSet: model.dailyGoalMinutes != nil) {
                    model.saveWork(schedule: schedule, goalMinutes: goal)
                }
            }
            .wpCard(strong: true)
            .wpRise(1)
            Text("Changes apply from today. Earlier days keep their goals. WorkPulse calculates your weekly and monthly goals from your daily goal and your work days.")
                .font(WP.font(12)).foregroundStyle(WP.caption).fixedSize(horizontal: false, vertical: true)
                .wpRise(2)
        }
        .onAppear(perform: load)
        .onChange(of: model.settings.schedule) { load() }
        .onChange(of: model.dailyGoalMinutes) { load() }
    }

    private func load() {
        schedule = model.settings.schedule
        goal = model.dailyGoalMinutes ?? WorkDayEditor.defaultGoal
    }
}

/// Work hours and the daily goal as one unit: the goal can never be longer than the work hours.
/// Used on the Work screen and in onboarding. `commit` runs when an edit is complete.
struct WorkDayEditor: View {
    static let defaultGoal = 360

    @Binding var schedule: WorkSchedule
    /// Daily goal in minutes.
    @Binding var goal: Int
    let firstWeekday: Int
    /// False while no daily goal is stored yet.
    var goalIsSet = true
    /// The label of the switch ("Use work hours").
    var switchLabel = "Use work hours"
    var commit: () -> Void = {}

    private var off: Bool { !schedule.enabled }
    /// The goal is at most the length of the work hours, in steps of 30 minutes.
    private var goalMax: Int { off ? 720 : max(30, schedule.lengthMinutes / 30 * 30) }
    private var shownGoal: Int { min(max(30, goal), goalMax) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(switchLabel, isOn: Binding(get: { schedule.enabled }, set: { schedule.enabled = $0; clampAndCommit() }))
                .toggleStyle(WPSwitchStyle())
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Work days")
                DayChips(days: Binding(get: { schedule.days }, set: { schedule.days = $0; commit() }), firstWeekday: firstWeekday)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Work days")
            }
            .disabled(off).opacity(off ? 0.45 : 1)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 32) { dial; times.frame(minWidth: 220, maxWidth: 340) }
                VStack(spacing: 16) { dial; times }
            }
            .frame(maxWidth: .infinity)
            goalSlider
                .padding(.top, 14)
                .overlay(alignment: .top) { Rectangle().fill(WP.hairline).frame(height: 1) }
        }
        .animation(.easeInOut(duration: 0.25), value: off)
    }

    private var dial: some View {
        VStack(spacing: 6) {
            WorkDial(start: $schedule.startMinutes, end: $schedule.endMinutes, onCommit: clampAndCommit)
            Text("Drag the arc or a handle.").font(WP.font(12)).foregroundStyle(WP.caption)
        }
        .disabled(off).opacity(off ? 0.45 : 1)
    }

    private var times: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                timeField("Start", $schedule.startMinutes, other: schedule.endMinutes)
                timeField("End", $schedule.endMinutes, other: schedule.startMinutes)
            }
            .disabled(off).opacity(off ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 4) {
                rule("play.fill", "At Start, WorkPulse changes to the Work profile.")
                rule("stop.fill", "At End, WorkPulse tells you that work hours ended.")
            }
        }
    }

    private func timeField(_ label: String, _ minutes: Binding<Int>, other: Int) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { value in
                let c = Calendar.current.dateComponents([.hour, .minute], from: value)
                let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                guard m != other else { return }   // Start and End must differ
                minutes.wrappedValue = m
                clampAndCommit()
            })
        return VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            HStack(spacing: 0) {
                WPDateField(selection: date, size: 15, weight: .semibold).accessibilityLabel(label)
                Spacer(minLength: 0)
            }
            .wpField(height: 40, radius: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(WP.textBlue).frame(width: 11)
            Text(text).font(WP.font(12)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
                     label: "Daily goal", valueText: Fmt.minutes(shownGoal), onCommit: commit)
            Text(relation(length)).font(WP.font(12)).monospacedDigit().foregroundStyle(WP.secondary)
        }
    }

    private func relation(_ length: Int) -> String {
        if !goalIsSet { return "No daily goal is set. Move the slider to set one." }
        if off { return "The goal applies on your work days." }
        return shownGoal >= length ? "This leaves no time for breaks." : "This leaves \(Fmt.minutes(length - shownGoal)) for breaks."
    }

    private func clampAndCommit() {
        goal = shownGoal
        commit()
    }
}

/// A 24-hour dial. Drag a handle to change Start or End; drag the arc to move both and keep
/// the length. Arrow keys move by 5 minutes, Page Up and Page Down by 1 hour.
struct WorkDial: View {
    @Binding var start: Int
    @Binding var end: Int
    var onCommit: () -> Void = {}

    private enum Part: Hashable { case start, end, arc }
    @State private var dragging: Part?
    @State private var grabOffset = 0
    @FocusState private var focus: Part?
    @Environment(\.isEnabled) private var enabled

    private let size: CGFloat = 208
    private let radius: CGFloat = 84
    private var length: Int { ((end - start) % 1440 + 1440) % 1440 }

    var body: some View {
        ZStack {
            Circle().stroke(WP.track, lineWidth: 24).frame(width: radius * 2, height: radius * 2)
            DialArc(start: start, length: length).stroke(WP.cobalt, style: StrokeStyle(lineWidth: 24, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .overlay {
                    if focus == .arc {
                        DialArc(start: start, length: length).stroke(WP.textBlue, style: StrokeStyle(lineWidth: 30, lineCap: .round)).opacity(0.35)
                    }
                }
                .focusable(enabled, interactions: .activate).focused($focus, equals: .arc).focusEffectDisabled()
                .onKeyPress(keys: Self.keys) { press in step(.arc, press.key) }
                .accessibilityElement()
                .accessibilityLabel("Move work hours")
                .accessibilityValue("\(Fmt.time(minutes: start)) to \(Fmt.time(minutes: end))\(end < start ? ", next day" : "")")
                .accessibilityAdjustableAction { move(.arc, by: $0 == .increment ? 5 : -5); onCommit() }
            ticks
            ForEach([(0, "00"), (360, "06"), (720, "12"), (1080, "18")], id: \.0) { minute, text in
                Text(text).font(WP.font(11, .semibold)).foregroundStyle(WP.secondary).position(point(minute, 46))
            }
            .accessibilityHidden(true)
            VStack(spacing: 0) {
                Text(Fmt.minutes(length)).font(WP.font(15, .bold)).monospacedDigit().foregroundStyle(WP.ink)
                Text("start to end").font(WP.font(11, .medium)).foregroundStyle(WP.caption)
            }
            .accessibilityElement(children: .combine)
            handle(.start, "play.fill", "Start of work hours")
            handle(.end, "stop.fill", "End of work hours")
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(drag)
    }

    private static let keys: Set<KeyEquivalent> = [.leftArrow, .rightArrow, .upArrow, .downArrow, .pageUp, .pageDown]

    private var ticks: some View {
        Canvas { context, _ in
            var path = Path()
            for hour in 0..<24 {
                path.move(to: point(hour * 60, 68))
                path.addLine(to: point(hour * 60, hour % 6 == 0 ? 60 : 64))
            }
            context.stroke(path, with: .color(WP.caption), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func handle(_ part: Part, _ symbol: String, _ label: String) -> some View {
        let minutes = part == .start ? start : end
        return Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(WP.fixedBlue)
            .frame(width: 30, height: 30)
            .background(.white, in: Circle())
            .overlay(Circle().strokeBorder(WP.cobalt, lineWidth: 2))
            .overlay { if focus == part { Circle().stroke(WP.textBlue, lineWidth: 3).padding(-4) } }
            .shadow(color: WP.navy.opacity(0.28), radius: 3, y: 2)
            .scaleEffect(dragging == part ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: dragging)
            .position(point(minutes, radius))
            .focusable(enabled, interactions: .activate).focused($focus, equals: part).focusEffectDisabled()
            .onKeyPress(keys: Self.keys) { press in step(part, press.key) }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(Fmt.time(minutes: minutes))
            .accessibilityAdjustableAction { move(part, by: $0 == .increment ? 5 : -5); onCommit() }
    }

    // MARK: Geometry

    /// The point for `minutes` after midnight at distance `r` from the centre (00 at the top, clockwise).
    private func point(_ minutes: Int, _ r: CGFloat) -> CGPoint {
        let angle = CGFloat(minutes) / 1440 * 2 * .pi
        return CGPoint(x: size / 2 + r * CoreGraphics.sin(angle), y: size / 2 - r * CoreGraphics.cos(angle))
    }

    /// The time under a point, to the nearest 5 minutes.
    private func minutes(at location: CGPoint) -> Int {
        var degrees = atan2(location.x - size / 2, -(location.y - size / 2)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return Int((degrees / 360 * 288).rounded()) * 5 % 1440
    }

    // MARK: Changes

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    guard let part = part(at: value.startLocation) else { return }
                    dragging = part
                    focus = part
                    grabOffset = ((minutes(at: value.startLocation) - start) % 1440 + 1440) % 1440
                }
                let m = minutes(at: value.location)
                switch dragging {
                case .start: set(.start, m)
                case .end: set(.end, m)
                case .arc: shift(to: m - grabOffset)
                case nil: break
                }
            }
            .onEnded { _ in
                if dragging != nil { onCommit() }
                dragging = nil
            }
    }

    /// The part under a point: a handle first, then the arc.
    private func part(at location: CGPoint) -> Part? {
        func near(_ m: Int) -> Bool { hypot(location.x - point(m, radius).x, location.y - point(m, radius).y) <= 20 }
        if near(start) { return .start }
        if near(end) { return .end }
        let distance = hypot(location.x - size / 2, location.y - size / 2)
        guard abs(distance - radius) <= 16 else { return nil }
        let offset = ((minutes(at: location) - start) % 1440 + 1440) % 1440
        return offset <= length ? .arc : nil
    }

    private func set(_ part: Part, _ minutes: Int) {
        let m = (minutes % 1440 + 1440) % 1440
        if part == .start { if m != end { start = m } } else if m != start { end = m }   // Start and End must differ
    }

    /// Moves Start to `minutes` and keeps the length.
    private func shift(to minutes: Int) {
        let keep = length
        start = (minutes % 1440 + 1440) % 1440
        end = (start + keep) % 1440
    }

    private func move(_ part: Part, by delta: Int) {
        switch part {
        case .start: set(.start, start + delta)
        case .end: set(.end, end + delta)
        case .arc: shift(to: start + delta)
        }
    }

    private func step(_ part: Part, _ key: KeyEquivalent) -> KeyPress.Result {
        let delta: Int = switch key {
        case .rightArrow, .upArrow: 5
        case .leftArrow, .downArrow: -5
        case .pageUp: 60
        default: -60
        }
        move(part, by: delta)
        onCommit()
        return .handled
    }
}

/// The arc from `start` (minutes after midnight) for `length` minutes, clockwise from the top.
private struct DialArc: Shape {
    var start: Int
    var length: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let from = Angle.degrees(Double(start) / 4 - 90)
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: from, endAngle: from + .degrees(Double(length) / 4), clockwise: false)
        return path
    }
}
