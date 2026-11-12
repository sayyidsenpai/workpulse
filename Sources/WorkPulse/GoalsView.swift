import SwiftUI
import WorkPulseCore

/// Optional goals, overall and per project/work profile. Saving writes a new version effective
/// today; earlier periods keep being judged by the version that applied to them.
struct GoalsView: View {
    @Environment(AppModel.self) private var model
    @State private var profile: Int64?  // nil = overall
    @State private var draft = GoalConfig(effectiveFrom: .today())
    @State private var results: [PeriodResult] = []

    private var query: [AnyHashable] { [profile, model.revision] }
    private var versions: [GoalConfig] { model.goals.filter { $0.projectID == profile }.reversed() }

    var body: some View {
        Form {
            Section {
                Picker("Goals for", selection: $profile) {
                    Text("All work (overall)").tag(Int64?.none)
                    ForEach(model.projects) { Text($0.name).tag(Int64?.some($0.id)) }
                }
                Text("Goals are optional and only measure progress. They never start, stop or change tracking. Each project can have its own goals; add projects under Apps & Rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Targets") {
                TextField("Daily hours", value: $draft.dailyHours, format: .number, prompt: Text("No target"))
                TextField("Weekly hours", value: $draft.weeklyHours, format: .number, prompt: Text("No target"))
                TextField("Monthly hours", value: $draft.monthlyHours, format: .number, prompt: Text("No target"))
                Picker("Working days per week", selection: $draft.weeklyDays) {
                    Text("No target").tag(Int?.none)
                    ForEach(1...7, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
            }

            Section("Working days") {
                LabeledContent("Scheduled days") {
                    WeekdayPicker(days: $draft.workingDays, firstWeekday: model.settings.firstWeekday)
                }
                Stepper("A day counts as worked after \(draft.minDayMinutes) minutes", value: $draft.minDayMinutes, in: 0...720, step: 15)
                Text("The daily target applies on scheduled days. Any day that reaches the minimum counts as a working day.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Save Goals", action: save).keyboardShortcut(.defaultAction)
                        .help("Applies from today. Earlier periods keep their previous goals.")
                }
            }

            Section("Progress") {
                ForEach(results, id: \.period) { result in
                    LabeledContent(label(result.period)) { Text(describe(result)).monospacedDigit() }
                }
            }

            Section("Goal versions") {
                if versions.isEmpty { Text("No goals set for this profile.").foregroundStyle(.secondary) }
                ForEach(versions) { version in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("From \(Fmt.day(version.effectiveFrom))")
                            Text(describe(version)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.edit { try model.store.deleteGoal(version.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove this version")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: query, initial: true) { load() }
        .onChange(of: profile) { resetDraft() }
        .onAppear(perform: resetDraft)
    }

    private func resetDraft() {
        var current = Goals.config(on: .today(), projectID: profile, in: model.goals) ?? GoalConfig(projectID: profile, effectiveFrom: .today())
        current.id = 0
        current.effectiveFrom = .today()
        draft = current
    }

    private func load() {
        let today = LocalDay.today()
        let week = Period.week.range(containing: today, firstWeekday: model.settings.firstWeekday)
        let totals = model.totals(days: min(week.lowerBound, today.monthStart)...max(week.upperBound, today.monthEnd), projectID: profile)
        results = Period.allCases.map { model.evaluate($0, totals, projectID: profile) }
    }

    private func save() {
        var goal = draft
        goal.projectID = profile
        goal.effectiveFrom = .today()
        goal.dailyHours = goal.dailyHours.map { min(24, max(0, $0)) }
        goal.weeklyHours = goal.weeklyHours.map { min(168, max(0, $0)) }
        goal.monthlyHours = goal.monthlyHours.map { min(744, max(0, $0)) }
        model.edit { try model.store.saveGoal(goal) }
        resetDraft()
    }

    private func label(_ period: Period) -> String {
        switch period {
        case .day: "Today"
        case .week: "This week"
        case .month: "This month"
        }
    }

    private func describe(_ r: PeriodResult) -> String {
        var text = Fmt.duration(r.workSeconds)
        if let target = r.targetSeconds {
            text += " of \(Fmt.duration(target))"
            text += r.workSeconds >= target ? " · reached" : " · \(Fmt.duration(target - r.workSeconds)) left"
        }
        if r.period != .day {
            text += " · \(r.workingDays)\(r.daysTarget.map { " of \($0)" } ?? "") working days"
        }
        return text
    }

    private func describe(_ g: GoalConfig) -> String {
        func hours(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        var parts: [String] = []
        if let v = g.dailyHours { parts.append("\(hours(v)) h per day") }
        if let v = g.weeklyHours { parts.append("\(hours(v)) h per week") }
        if let v = g.monthlyHours { parts.append("\(hours(v)) h per month") }
        if let v = g.weeklyDays { parts.append("\(v) days per week") }
        parts.append("day counts after \(g.minDayMinutes) min")
        parts.append(g.workingDays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: " "))
        return parts.joined(separator: " · ")
    }
}
