import SwiftUI
import WorkPulseCore

/// The menu bar popover: the status with its two actions, the application in front, work time
/// against the goals, and the way into the main window.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }
            if model.engine.clockBehind {
                Note(tone: .warn, text: "The system clock is behind the latest recorded session. WorkPulse adds new time after that session until the clock is correct.")
            }
            if model.confirmingDayOff {
                DayOffConfirm().transition(.opacity)
            } else {
                HeroCard(hero: model.hero)
            }
            frontApplication
            if model.agentConnected {
                Toggle("Count agent work as my work", isOn: model.binding(\.countAgentWork))
                    .toggleStyle(WPSwitchStyle())
                    .padding(.vertical, -2)   // 10 pt above and below, as in the design
                    .wpCard(padding: 12)
                    .transition(.opacity)
            }
            WorkTimeCard()
            TodayMix()
            footer
        }
        .padding(14)
        .frame(width: 392)
        .background(Wallpaper().opacity(0.5))
        .onAppear { model.refresh() }
        .onDisappear {
            // The question about a day off is asked one time; it does not come back.
            model.offerDayOff = false
            model.confirmingDayOff = false
        }
    }

    // MARK: Application in front

    private var frontApplication: some View {
        HStack(spacing: 12) {
            AppTile(name: model.frontApp?.name, bundleID: model.frontApp?.bundleID)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.frontApp?.name ?? "No application").font(WP.font(14, .semibold)).foregroundStyle(WP.ink).lineLimit(1)
                Text("Application in front").font(WP.font(12)).foregroundStyle(WP.caption)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("Category")
                if let app = model.frontApp {
                    WPMenu("Category", selection: categoryBinding(app), options: model.categories.map { ($0.id, $0.name) })
                    .help(Browsers.isBrowser(app.bundleID)
                          ? "WorkPulse does not read tabs or sites. This category applies to all time in \(app.name)."
                          : "The category for time in \(app.name) from now on")
                } else {
                    WPMenu("Category", selection: .constant(Store.uncategorizedID), options: [(Store.uncategorizedID, "Uncategorized")])
                        .disabled(true)
                }
            }
            .frame(width: 150, alignment: .leading)
        }
        .wpCard(padding: 12)
    }

    private func categoryBinding(_ app: TrackingEngine.FrontApp) -> Binding<Int64> {
        Binding(get: { model.rule(for: app.bundleID)?.categoryID ?? Store.uncategorizedID },
                set: { id in
                    var rule = model.rule(for: app.bundleID) ?? AppRule(bundleID: app.bundleID, appName: app.name)
                    rule.categoryID = id
                    model.setRule(rule)
                })
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { tab in
                FooterButton(title: tab.rawValue, symbol: tab.symbol) { model.showMain(tab) }
            }
            Rectangle().fill(WP.hairline).frame(width: 1, height: 36)
            FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(WP.hairline).frame(height: 1) }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                Text(title).font(WP.font(11, .medium))
            }
            .foregroundStyle(WP.secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(hovered ? WP.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Status

extension AppModel {
    /// One hero per state. Every state has its own colour, icon, title and sentence.
    var hero: Hero {
        let model = self
        // In the Work profile the big number is "This session": work recorded since the work session
        // began. It counts only while work is recorded; idle and other applications stop it.
        let session = model.summary.sessionWork, asOf = model.summary
        let working = model.isWorking
        let thisSession: (Date) -> String = { Fmt.clock(session + asOf.live(at: $0, working: working)) }
        let hours = model.workHoursNote
        let goal = model.goalReached
        // One action while working: End work. It becomes the strong button once the daily goal is reached.
        let end = HeroAction(label: "End work", symbol: "stop.fill", fill: goal ? .white : WP.navy.opacity(0.32),
                             text: goal ? WP.fixedBlue : .white) { model.endWork() }
        let lightEnd = HeroAction(label: "End work", symbol: "stop.fill", fill: WP.track, text: WP.ink) { model.endWork() }

        switch model.headline {
        case .overtime:
            // All work outside work hours today, the same number as in the Today card.
            let overtime = model.summary.overtime
            return Hero(title: model.statusText, symbol: "clock", live: true,
                        label: "Overtime today", big: { Fmt.clock(overtime + asOf.live(at: $0, working: working)) }, meta: hours,
                        note: "You can stop now. Make time to rest.",
                        fill: WP.navy, text: .white, sub: WP.onNavy,
                        second: HeroAction(label: "End work", symbol: "stop.fill", fill: .white, text: WP.navy) { model.endWork() })
        case .agent:
            return Hero(title: model.statusText, symbol: "terminal", live: true,
                        label: "This session", big: thisSession, meta: hours,
                        note: "An agent works for you. This time counts as work, also when you are idle.",
                        fill: WP.cobalt, text: .white, sub: WP.onCobalt, striped: true, second: end)
        case .tracking:
            return Hero(title: model.statusText, symbol: "record.circle", live: true,
                        label: "This session", big: thisSession, meta: hours,
                        fill: WP.cobalt, text: .white, sub: WP.onCobalt, second: end)
        case .nonwork, .ignored, .waiting:
            let app = model.frontApp?.name ?? "this application"
            return Hero(title: model.statusText, symbol: "minus.circle",
                        label: "This session", big: thisSession, meta: hours,
                        note: model.headline == .ignored ? "WorkPulse does not count time in \(app)."
                            : model.headline == .waiting ? "WorkPulse counts when you use an application."
                            : "Time in \(app) is not work time.",
                        fill: WP.heroLight, text: WP.ink, sub: WP.secondary, second: lightEnd)
        case .idle:
            let since = model.idleSince
            return Hero(title: model.statusText, symbol: "moon",
                        label: since.map { "Idle since \(Fmt.time($0))" } ?? "Idle",
                        big: { now in Fmt.clock(since.map { now.timeIntervalSince($0) } ?? 0) }, meta: hours,
                        note: "Idle time is not work time. WorkPulse counts again when you use the Mac.",
                        fill: WP.amber, text: WP.amberInk, sub: WP.amberInk,
                        second: HeroAction(label: "End work", symbol: "stop.fill", fill: WP.amberInk.opacity(0.16), text: WP.amberInk) { model.endWork() })
        case .personal, .dayOff:
            let next = model.nextWorkHoursStart
            var hero = Hero(title: model.statusText, symbol: "person.crop.circle",
                            label: next == nil ? "Work hours" : "Next work hours", big: { _ in next.map(Fmt.dayTime) ?? "Not set" },
                            note: "WorkPulse does not count work time now.",
                            fill: WP.heroLight, text: WP.ink, sub: WP.secondary)
            if model.headline == .dayOff {
                hero.symbol = "calendar.badge.minus"
                let moved = model.dayOffUndo?.movedSeconds ?? 0
                hero.note = moved >= 1 ? "Today is a day off. WorkPulse moved \(Fmt.duration(moved)) of work to Personal."
                                       : "Today is a day off. WorkPulse counts no work time today."
                if model.dayOffUndo != nil {
                    hero.first = HeroAction(label: "Undo", symbol: "arrow.uturn.backward", fill: WP.track, text: WP.ink) { model.undoDayOff() }
                }
                hero.second = HeroAction(label: model.startLabel, symbol: "play.fill", fill: WP.field, text: WP.ink) { model.startWork() }
            } else if model.offerDayOff, let end = model.workHoursEnd {
                // The user ended work early, in this popover: ask about a day off, one time.
                hero.note = "Work hours continue until \(Fmt.time(end)). Is today a day off?"
                hero.first = HeroAction(label: "Day off", symbol: "calendar.badge.minus", fill: WP.cobalt, text: .white) { model.requestDayOff() }
                hero.second = HeroAction(label: model.startLabel, symbol: "play.fill", fill: WP.field, text: WP.ink) { model.startWork() }
            } else if let ask = model.suggestion {
                hero.note = "You used \(ask.app) for \(ask.minutes) minutes. Is this work?"
                hero.first = HeroAction(label: model.startLabel, symbol: "play.fill", fill: WP.cobalt, text: .white) { model.startWork(includeEvidence: true) }
                hero.second = HeroAction(label: "Not work", symbol: "xmark", fill: WP.track, text: WP.ink) { model.notWork() }
            } else {
                hero.second = HeroAction(label: model.startLabel, symbol: "play.fill", fill: WP.field, text: WP.ink) { model.startWork() }
            }
            return hero
        }
    }
}

// MARK: - Hero

struct HeroAction {
    let label: String
    let symbol: String
    let fill: Color
    let text: Color
    let action: () -> Void

    /// What the button does, as a tooltip and a VoiceOver hint. One text per button everywhere.
    var hint: String? {
        switch label {
        case "End work": "Stop work for today. WorkPulse changes to Personal."
        case "Start work", "Start overtime": "WorkPulse changes to Work and counts your work."
        default: nil
        }
    }
}

struct Hero {
    var title: String
    var symbol: String
    var live = false
    var label: String
    /// The large value; gets the current time so clocks count every second.
    var big: (Date) -> String
    var meta = ""
    var note = ""
    var fill: Color
    var text: Color
    var sub: Color
    /// Diagonal stripes: the second signal for agent work.
    var striped = false
    var first: HeroAction?
    var second: HeroAction?
}

/// The status card. Colour, icon, title and sentence change together with the state.
struct HeroCard: View {
    let hero: Hero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LiveSymbol(name: hero.symbol, size: 16, color: hero.text, live: hero.live).frame(width: 20, height: 20)
                    .id(hero.symbol + (hero.live ? "-live" : ""))
                Text(hero.title).font(WP.font(14, .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Text(hero.meta).font(WP.font(12, .semibold)).monospacedDigit().foregroundStyle(hero.sub)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(hero.label).font(WP.font(12, .medium)).foregroundStyle(hero.sub).lineLimit(1)
                Live { now in
                    Text(hero.big(now)).font(WP.font(48, .bold)).tracking(-1).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            if !hero.note.isEmpty {
                Text(hero.note).font(WP.font(13, .medium)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach([hero.first, hero.second].compactMap { $0 }, id: \.label) { action in
                    Button(action: action.action) {
                        Label(action.label, systemImage: action.symbol)
                    }
                    .buttonStyle(WPButtonStyle(fill: action.fill, text: action.text, height: 40, radius: 10, expand: true))
                    .help(action.hint ?? "")
                    .accessibilityHint(action.hint ?? "")
                }
            }
        }
        .foregroundStyle(hero.text)
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .leading)
        .background {
            ZStack {
                hero.fill
                if hero.striped { Hatch(color: WP.navy.opacity(0.16), width: 12, gap: 12) }
                LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.02))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: hero.fill.opacity(0.3), radius: 12, y: 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: hero.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }
}

// MARK: - Work time

/// Work time today, this week and this month against the goals, counting live while work is tracked.
struct WorkTimeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Live { now in
            let live = model.summary.live(at: now, working: model.isWorking)
            VStack(alignment: .leading, spacing: 14) {
                today(live)
                HStack(alignment: .top, spacing: 14) {
                    period("This week", model.summary.week, live)
                    period("This month", model.summary.month, live)
                }
                .padding(.horizontal, 6)
                workingDays
                    .padding(.top, 12)
                    .overlay(alignment: .top) { Rectangle().fill(WP.hairline).frame(height: 1) }
                    .padding(.horizontal, 6)
            }
            .padding(.bottom, 6)   // 8 pt at the sides and top, 14 pt at the bottom
            .wpCard(padding: 8)
        }
    }

    private func today(_ live: TimeInterval) -> some View {
        let work = model.summary.today.work + live
        let target = model.summary.day?.targetSeconds.flatMap { $0 > 0 ? $0 : nil }
        let reached = target.map { work >= $0 } ?? false
        let overtime = model.summary.overtime + (model.isOvertime ? live : 0)
        // Whole minutes on both sides, so "2h 45m" and "3h 15m left" always add up to the goal.
        let shown = work >= 60 ? (work / 60).rounded(.down) * 60 : work.rounded(.down)
        var caption = target.map { reached ? "Goal of \(Fmt.duration($0, seconds: false)) reached" : "\(Fmt.duration($0 - shown)) left" } ?? (model.isDayOff ? "Day off. No daily goal today." : "No goal for today")
        if overtime >= 60 { caption += " · \(Fmt.duration(overtime, seconds: false)) outside work hours" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(WP.font(13, .semibold))
                Spacer()
                Text(Fmt.duration(work)).font(WP.font(20, .bold)).monospacedDigit()
                if let target {
                    Text("of \(Fmt.duration(target, seconds: false))").font(WP.font(12)).monospacedDigit().foregroundStyle(WP.secondary)
                }
            }
            WPBar(fraction: target.map { work / $0 } ?? 0, color: reached ? WP.green : WP.cobalt, label: "Today")
            HStack(spacing: 6) {
                if reached {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(WP.green).transition(.scale.combined(with: .opacity))
                }
                Text(caption).font(WP.font(12, reached ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(reached ? WP.greenInk : WP.secondary)
            }
        }
        .foregroundStyle(WP.ink)
        .padding(.horizontal, 6).padding(.vertical, 8)
        .background(reached ? WP.greenBg : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.6), value: reached)
    }

    private func period(_ title: String, _ result: PeriodResult?, _ live: TimeInterval) -> some View {
        let work = (result?.workSeconds ?? 0) + live
        let target = result?.targetSeconds.flatMap { $0 > 0 ? $0 : nil }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WP.font(13, .medium)).foregroundStyle(WP.ink)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.duration(work, seconds: false)).font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
                if let target { Text("of \(Fmt.duration(target, seconds: false))").font(WP.font(12)).foregroundStyle(WP.caption) }
            }
            .monospacedDigit().lineLimit(1)
            WPBar(fraction: target.map { work / $0 } ?? 0, height: 6, label: title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workingDays: some View {
        let days = model.summary.weekDays
        return HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                Text("Working days this week")
                Text("Working days")
            }
            .font(WP.font(13, .medium)).foregroundStyle(WP.ink).lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                ForEach(days, id: \.day) { item in
                    // Filled: a planned day with work. Solid ring: work on a day that was not planned
                    // (a weekend, a day off); it counts, like in Reports. Dashed ring: a planned day
                    // without work. Struck through: a day off.
                    let filled = item.worked && !item.extra
                    Text(String(Calendar.current.veryShortWeekdaySymbols[item.day.weekday - 1]))
                        .font(WP.font(11, .bold))
                        .strikethrough(item.off)
                        .foregroundStyle(filled ? Color.white : item.extra ? WP.textBlue : WP.secondary)
                        .frame(width: 20, height: 20)
                        .background(filled ? WP.cobalt : item.off ? WP.heroLight : .clear, in: Circle())
                        .overlay {
                            if item.extra { Circle().strokeBorder(WP.cobalt, lineWidth: 1.5) }
                            else if item.off { Circle().strokeBorder(WP.switchOff, lineWidth: 1.5) }
                            else if !item.worked { Circle().strokeBorder(WP.caption, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
                        }
                }
            }
            .accessibilityHidden(true)
            // Every day with work counts, the same as Reports and the weekly days goal.
            let extra = days.filter(\.extra).count
            let goal = model.summary.week?.daysGoal.map { " of \($0)" } ?? ""
            Text("\(days.filter(\.worked).count)\(goal)")
                .font(WP.font(13, .semibold)).monospacedDigit().foregroundStyle(WP.ink)
                .help(extra > 0 ? "Includes work on \(extra) day\(extra == 1 ? "" : "s") outside your work days." : "")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working days this week: \(days.filter(\.worked).count)\(model.summary.week?.daysGoal.map { " of \($0)" } ?? "")"
            + (days.contains(where: \.extra) ? ", including \(days.filter(\.extra).count) outside your work days" : ""))
    }
}

/// Today by type: applications, agent, idle. Agent and idle have stripes as well as a colour.
struct TodayMix: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let today = model.summary.today
        let agent = model.summary.agent
        // Own work + agent = Today's work. Non-work is its own part: it is never shown as work.
        let own = max(0, today.work - agent)
        let showAgent = model.agentConnected && agent >= 1
        let total = max(1, today.work + today.nonwork + today.idle)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(own / total, geo.size.width) { WP.cobalt }
                    segment(agent / total, geo.size.width) { ZStack { WP.cobalt; Hatch(color: WP.navy, width: 2, gap: 4) } }
                    segment(today.nonwork / total, geo.size.width) { WP.switchOff }
                    segment(today.idle / total, geo.size.width) { ZStack { WP.amber; Hatch(color: WP.amberHatch, width: 2, gap: 4) } }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 8)
            .background(WP.track)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            let legends = Group {
                legend("Work \(Fmt.duration(own))") { WP.cobalt }
                if showAgent {
                    legend("Agent \(Fmt.duration(agent))") { ZStack { WP.cobalt; Hatch(color: WP.navy, width: 2, gap: 3) } }
                }
                if today.nonwork >= 60 { legend("Non-work \(Fmt.duration(today.nonwork))") { WP.switchOff } }
                legend("Idle \(Fmt.duration(today.idle))") { ZStack { WP.amber; Hatch(color: WP.amberHatch, width: 2, gap: 3) } }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { legends }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) { legends }
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: work \(Fmt.duration(own))" + (showAgent ? ", agent \(Fmt.duration(agent))" : "")
            + ", non-work \(Fmt.duration(today.nonwork)), idle \(Fmt.duration(today.idle)), ignored \(Fmt.duration(today.excluded))")
    }

    @ViewBuilder
    private func segment(_ share: Double, _ width: CGFloat, @ViewBuilder fill: () -> some View) -> some View {
        if share > 0 {
            fill().frame(width: max(4, (width - 4) * share)).clipShape(Capsule())
        }
    }

    private func legend(_ text: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 6) {
            swatch().frame(width: 10, height: 10).clipShape(RoundedRectangle(cornerRadius: 3))
            Text(text).font(WP.font(12)).monospacedDigit().foregroundStyle(WP.secondary).lineLimit(1)
        }
    }
}

// MARK: - Day off

/// "Make today a day off?": shown in place of the status card, with the work recorded today.
struct DayOffConfirm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let work = model.todayWork
        let total = work.apps.reduce(0) { $0 + $1.seconds }
        let rows = Array(work.apps.prefix(3)) + (work.apps.count > 3
            ? [(name: "Other applications", bundleID: String?.none, seconds: work.apps.dropFirst(3).reduce(0) { $0 + $1.seconds })] : [])
        let daily = model.summary.day?.targetSeconds
        let week = model.summary.week?.targetSeconds
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text("Make today a day off?").font(WP.font(15, .bold)).foregroundStyle(WP.ink).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { model.confirmingDayOff = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(WP.ink)
                        .frame(width: 28, height: 28).background(WP.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel")
            }
            // The span of the recorded work, not "now": the work can have ended hours ago.
            Text(work.from.flatMap { from in work.to.map { "WorkPulse recorded this work today, from \(Fmt.time(from)) to \(Fmt.time($0)):" } }
                 ?? "WorkPulse recorded this work today:")
                .font(WP.font(13)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        AppTile(name: row.name, bundleID: row.bundleID, symbol: row.bundleID == nil && row.name == "Other applications" ? "square.grid.2x2" : nil, size: 24)
                        Text(row.name).font(WP.font(13, .medium)).foregroundStyle(WP.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Fmt.duration(row.seconds)).font(WP.font(13)).monospacedDigit().foregroundStyle(WP.ink)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(WP.hairline).frame(height: 1) }
                }
                HStack {
                    Text("Total").font(WP.font(13, .semibold))
                    Spacer()
                    Text(Fmt.duration(total)).font(WP.font(13, .bold)).monospacedDigit()
                }
                .foregroundStyle(WP.ink)
                .padding(.vertical, 8)
            }
            .overlay(alignment: .top) { Rectangle().fill(WP.hairline).frame(height: 1) }
            VStack(alignment: .leading, spacing: 6) {
                if daily != nil { effect("Your daily goal does not apply today.") }
                if let week, let daily, week > daily {
                    effect("This week's goal changes from \(Fmt.duration(week, seconds: false)) to \(Fmt.duration(week - daily, seconds: false)).")
                }
                effect("WorkPulse does not start work again today.")
            }
            Text("Move this \(Fmt.duration(total)) to Personal? Work that you keep counts as overtime.")
                .font(WP.font(13, .semibold)).foregroundStyle(WP.ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Keep as work") { model.takeDayOff(moveWork: false) }
                    .buttonStyle(WPButtonStyle(height: 40, radius: 10, expand: true))
                Button("Move to Personal") { model.takeDayOff(moveWork: true) }
                    .buttonStyle(WPButtonStyle(kind: .primary, height: 40, radius: 10, expand: true))
                    .shadow(color: WP.cobalt.opacity(0.3), radius: 5, y: 4)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(WP.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WP.hairline))
        .shadow(color: WP.navy.opacity(0.14), radius: 12, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Make today a day off?")
    }

    private func effect(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WP.textBlue)
            Text(text).font(WP.font(12)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
