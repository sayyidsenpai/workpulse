import SwiftUI
import WorkPulseCore

private struct PayRow: Identifiable {
    let month: LocalDay
    let amount: Double
    let currency: String
    let work: TimeInterval
    var id: Int { month.index }
    var hourly: Double? { Pay.hourly(monthlyAmount: amount, workSeconds: work) }
}

/// One bar of the work trend: a day, a week or a month.
private struct Bucket: Identifiable {
    let start: LocalDay
    let seconds: TimeInterval
    /// For the tooltip and VoiceOver: "Mon, 2 Nov 2026", "2 to 8 Nov 2026" or "November 2026".
    let name: String
    /// The period that contains today: its bar shows the work so far.
    let current: Bool
    /// The label below the bar. An empty `top` means no label.
    let top: String
    let bottom: String
    /// A day that is not a work day: its label is lighter.
    var muted = false
    var id: Int { start.index }
}

/// A label below the chart, at `x` from the left edge of all bars.
private struct AxisLabel: Identifiable {
    let id: Int
    let top: String
    let bottom: String
    let current: Bool
    let muted: Bool
    var x: CGFloat = 0
    /// An estimate that is never too small, so labels do not touch.
    var width: CGFloat { CGFloat(max(top.count, bottom.count)) * 7 + 8 }
}

private struct ReportData {
    var range = LocalDay.today()...LocalDay.today()
    var sessions: [Session] = []
    var totals: [LocalDay: DayTotals] = [:]
    var stats = RangeStats()
    /// Work time outside the work hours; nil when work hours are off.
    var overtime: TimeInterval?
    /// Today is in the period and counts as a working day.
    var includesToday = false
    /// The daily goal in force on the last day of the period, in seconds.
    var dailyGoal: TimeInterval?
    var apps: [(key: String, seconds: TimeInterval)] = []
    /// Bundle identifier by application name, for the icons.
    var appIDs: [String: String] = [:]
    var weeks: [PeriodResult] = []
    var months: [PeriodResult] = []
    var pay: [PayRow] = []
}

/// Analytics for a month, a year, or all time: totals, the work trend, time for each application,
/// goal history and the effective hourly compensation.
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var year = LocalDay.today().components.year  // 0 = all time
    @State private var month = LocalDay.today().components.month  // 0 = whole year
    @State private var granularity = Period.day
    @State private var goalPeriod = Period.week
    @State private var first = LocalDay.today()
    @State private var data = ReportData()

    private static let plotHeight: CGFloat = 180
    private static let labelHeight: CGFloat = 30
    /// Narrower bars are not legible: the chart scrolls sideways instead.
    private static let minSlot: CGFloat = 7

    private var query: [AnyHashable] { [year, month, model.revision] }

    var body: some View {
        Screen {
            ScreenHeader(title: "Reports", subtitle: "") { exportButtons }
            filters
            tiles
            trend
            Group {
                if balanced {
                    // Side by side when the goal card gets 452 pt (its table stays whole) and the
                    // applications card 308 pt; one height for both.
                    SideBySide(leading: 308, trailing: 452, spacing: 12, equalHeights: true) {
                        applications
                        goalHistory
                    }
                } else {
                    stacked
                }
            }
            if !data.pay.isEmpty { compensation }
        }
        .onChange(of: query, initial: true) { load() }
    }

    // MARK: Data

    /// The months of `year` that can hold data: from the first recorded day to today.
    private func months(in year: Int) -> [Int] {
        guard year != 0 else { return [] }
        let from = first.components, to = LocalDay.today().components
        let lower = year == from.year ? from.month : 1, upper = year == to.year ? to.month : 12
        return lower <= upper ? Array(lower...upper) : []
    }

    private func load() {
        let today = LocalDay.today()
        first = min((try? model.store.firstDay()) ?? today, today)
        // The selection must be a period that the menus offer (history can be deleted). The change loads again.
        if year != 0, year < first.components.year { year = first.components.year; month = 0; return }
        if month != 0, !months(in: year).contains(month) { month = 0; return }

        var lower = first, upper = today
        if year != 0, month != 0 {
            lower = LocalDay(year: year, month: month, day: 1)
            upper = lower.monthEnd
        } else if year != 0 {
            lower = LocalDay(year: year, month: 1, day: 1)
            upper = LocalDay(year: year, month: 12, day: 31)
        }
        // The period holds only days that can have data: from the first recorded day to today.
        upper = max(lower, min(upper, today))
        let range = min(max(lower, first), upper)...upper

        let firstWeekday = model.settings.firstWeekday
        let schedule = model.settings.schedule
        // Padded so weeks that straddle the range edges are evaluated on their full seven days.
        let sessions = (try? model.store.sessions(days: range.lowerBound.adding(-7)...range.upperBound.adding(7))) ?? []
        var d = ReportData()
        d.range = range
        d.totals = Aggregator.dayTotals(sessions)
        d.sessions = sessions.filter { s in Aggregator.split(s).contains { range.contains($0.day) } }
        d.stats = Aggregator.stats(d.totals, in: range, configs: model.goals)
        if schedule.isUsable {
            d.overtime = d.sessions.filter { $0.kind == .work }.reduce(0) { sum, s in
                Aggregator.split(s).filter { range.contains($0.day) }.reduce(sum) {
                    $0 + Aggregator.overtime([s], on: $1.day, schedule: schedule)
                }
            }
        }
        d.includesToday = range.contains(today) && Goals.isWorkingDay(d.totals[today]?.work ?? 0, on: today, configs: model.goals)
        d.dailyGoal = Goals.config(on: range.upperBound, projectID: nil, in: model.goals)?.dailyHours
            .flatMap { $0 > 0 ? $0 * 3600 : nil }
        d.apps = Aggregator.distribution(sessions, in: range, kinds: [.work]) { $0.appName ?? "Manual entry" }
        d.appIDs = Dictionary(sessions.compactMap { s in s.appName.flatMap { name in s.bundleID.map { (name, $0) } } }, uniquingKeysWith: { first, _ in first })
        d.weeks = Goals.history(.week, in: range, totals: d.totals, configs: model.goals, today: today, firstWeekday: firstWeekday,
                                isDayOff: model.isDayOff(_:))
        d.months = Goals.history(.month, in: range, totals: d.totals, configs: model.goals, today: today, firstWeekday: firstWeekday,
                                 isDayOff: model.isDayOff(_:))
        d.pay = d.months.compactMap { m in
            Pay.entry(on: min(m.range.upperBound, today), in: model.pay).map {
                PayRow(month: m.range.lowerBound, amount: $0.monthlyAmount, currency: $0.currency, work: m.workSeconds)
            }
        }
        data = d
    }

    /// "12 Nov 2026", "1 to 12 Nov 2026", "26 Oct to 1 Nov 2026".
    private func span(_ range: ClosedRange<LocalDay>, year: Bool) -> String {
        let names = Calendar.current.shortMonthSymbols
        let a = range.lowerBound.components, b = range.upperBound.components
        let end = "\(b.day) \(names[b.month - 1])" + (year ? " \(b.year)" : "")
        if range.lowerBound == range.upperBound { return end }
        let otherYear = a.year != b.year
        let start = "\(a.day)" + (otherYear || a.month != b.month ? " \(names[a.month - 1])" : "") + (year && otherYear ? " \(a.year)" : "")
        return "\(start) to \(end)"
    }

    private var periodName: String {
        if year == 0 { return "all time" }
        return month == 0 ? String(year) : Fmt.day(LocalDay(year: year, month: month, day: 1), "MMMMyyyy")
    }

    // MARK: Header and period

    private var exportButtons: some View {
        HStack(spacing: 8) {
            Button {
                let categories = Dictionary(uniqueKeysWithValues: model.categories.map { ($0.id, $0.name) })
                model.export(CSV.sessions(data.sessions, categories: categories, projects: [:]), name: "workpulse-sessions.csv")
            } label: {
                Label("Export Sessions…", systemImage: "arrow.down.to.line")
            }
            Button {
                let csv = CSV.daily(data.totals, in: data.range) { day, work in Goals.isWorkingDay(work, on: day, configs: model.goals) }
                model.export(csv, name: "workpulse-daily-summary.csv")
            } label: {
                Label("Export Daily Summary…", systemImage: "arrow.down.to.line")
            }
        }
        .buttonStyle(WPButtonStyle())
    }

    private var filters: some View {
        let today = LocalDay.today().components.year
        // A change of year keeps the month only if that year has it.
        let yearBinding = Binding(get: { year }, set: { value in
            if !months(in: value).contains(month) { month = 0 }
            year = value
        })
        return HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                FieldLabel("Year")
                WPMenu("Year", selection: yearBinding,
                       options: [(0, "All time")] + (first.components.year...today).reversed().map { ($0, String($0)) })
                    .frame(width: 104)
            }
            if year != 0 {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Month")
                    WPMenu("Month", selection: $month,
                           options: [(0, "Whole year")] + months(in: year).map { ($0, Calendar.current.monthSymbols[$0 - 1]) })
                        .frame(width: 148)
                }
            }
        }
    }

    // MARK: Summary

    private var tiles: some View {
        let work = tile("Tracked work", Fmt.duration(data.stats.work), span(data.range, year: true), more: overtimeText, hero: true)
        let days = tile("Working days", String(data.stats.workingDays),
                        data.includesToday ? "Includes today" : "of \(data.range.days.count) days")
        let average = tile("Average per working day", Fmt.duration(data.stats.averagePerWorkingDay),
                           data.dailyGoal.map { "Daily goal \(Fmt.duration($0))" } ?? "No daily goal")
        let goal = goalTile
        let monthly = tile(goal.title, goal.value, goal.detail, bar: goal.fraction)
        // Four in a row, or two rows of two: never a row with an empty place.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { work; days; average; monthly }
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) { work; days }.fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 12) { average; monthly }.fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Summary for \(periodName)")
    }

    private var overtimeText: String? {
        data.overtime.map { $0 >= 1 ? "overtime \(Fmt.duration($0))" : "no overtime" }
    }

    /// Work against the monthly goals of the period. Each monthly goal follows from the daily goal and the work days.
    private var goalTile: (title: String, value: String, detail: String, fraction: Double?) {
        let title = data.months.count > 1 ? "Monthly goals" : "Monthly goal"
        let months = data.months.filter { $0.targetSeconds != nil }
        let target = months.reduce(0) { $0 + ($1.targetSeconds ?? 0) }
        guard target > 0 else { return (title, "–", "No daily goal applied to this period.", nil) }
        let work = months.reduce(0) { $0 + $1.workSeconds }
        return (title, "\(Int((work / target * 100).rounded()))%", "\(Fmt.duration(work)) of \(Fmt.duration(target))", work / target)
    }

    /// `more` is the second part of the detail: on the same line, or on its own line in a narrow tile.
    private func tile(_ title: String, _ value: String, _ detail: String, more: String? = nil,
                      bar: Double? = nil, hero: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(WP.font(12, .medium)).foregroundStyle(hero ? WP.onCobalt : WP.caption)
            Text(value).font(WP.font(32, .bold)).tracking(-0.6).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(hero ? Color.white : WP.ink)
            if let bar { WPBar(fraction: bar, height: 6, label: title).padding(.vertical, 2) }
            ViewThatFits(in: .horizontal) {
                if let more { Text("\(detail) · \(more)").lineLimit(1) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                    if let more { Text(more).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .font(WP.font(12)).monospacedDigit().foregroundStyle(hero ? WP.onCobalt : WP.caption)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        // 120 is the height of the tile with the bar: the two rows of a narrow window are as high as each other.
        .frame(minWidth: 180, idealWidth: 180, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .topLeading)
        .background(hero ? WP.cobalt : WP.cardStrong, in: shape)
        .overlay {
            if hero {   // the light top edge of the artboard
                LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.03))
                    .clipShape(shape).allowsHitTesting(false)
            } else {
                shape.strokeBorder(WP.hairline)
            }
        }
        .shadow(color: hero ? WP.cobalt.opacity(0.3) : .clear, radius: 12, y: 10)
        .accessibilityElement(children: .combine)
    }

    // MARK: Work trend

    private var unit: String { granularity == .day ? "day" : granularity == .week ? "week" : "month" }

    private var trend: some View {
        let buckets = self.buckets
        let goal = granularity == .day ? data.dailyGoal : nil
        let segments = Segments(label: "Granularity",
                                options: [("Daily", Period.day), ("Weekly", Period.week), ("Monthly", Period.month)],
                                selection: $granularity)
        return VStack(alignment: .leading, spacing: 14) {
            heading("Work trend", "Hours of work for each \(unit)", control: segments)
            if buckets.contains(where: { $0.seconds > 0 }) {
                chart(buckets, goal: goal)
                legend(current: buckets.contains(where: \.current), goal: goal != nil)
            } else {
                emptyText("No work is recorded for this period.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wpCard(strong: true)
    }

    private var buckets: [Bucket] {
        let today = LocalDay.today(), range = data.range, firstWeekday = model.settings.firstWeekday
        let months = Calendar.current.shortMonthSymbols, weekdays = Calendar.current.shortWeekdaySymbols
        let oneMonth = range.lowerBound.monthStart == range.upperBound.monthStart
        let workDays = Goals.config(on: range.upperBound, projectID: nil, in: model.goals)?.workingDays
        return Aggregator.trend(data.totals, in: range, by: granularity, firstWeekday: firstWeekday).map { item -> Bucket in
            let full = granularity.range(containing: item.start, firstWeekday: firstWeekday)
            let shown = max(full.lowerBound, range.lowerBound)...min(full.upperBound, range.upperBound)
            let current = full.contains(today) && range.contains(today)
            let c = shown.lowerBound.components
            let name: String, top: String, bottom: String
            switch granularity {
            case .day:
                name = Fmt.day(item.start)
                if oneMonth || current {
                    top = String(c.day); bottom = current ? "Today" : weekdays[item.start.weekday - 1]
                } else if c.day == 1 {
                    top = months[c.month - 1]; bottom = String(c.year)   // many months: a label at the start of each month
                } else {
                    top = ""; bottom = ""
                }
            case .week:
                name = span(shown, year: true)
                top = String(c.day); bottom = current ? "This week" : months[c.month - 1]
            case .month:
                name = Fmt.day(item.start, "MMMMyyyy")
                top = months[c.month - 1]; bottom = current ? "This month" : String(c.year)
            }
            // Days that are not work days, and days off, have a muted label.
            let muted = granularity == .day && !current && (workDays?.contains(item.start.weekday) == false || model.isDayOff(item.start))
            return Bucket(start: item.start, seconds: item.seconds, name: name, current: current, top: top, bottom: bottom, muted: muted)
        }
    }

    /// The step between grid lines, in seconds, and the number of steps (5 at most).
    /// The top line is the first line at or above `peak`, so the bars fill the chart.
    private static func scale(_ peak: TimeInterval) -> (step: TimeInterval, ticks: Int) {
        let hours = max(peak, 60) / 3600
        let step = [0.25, 0.5, 1, 2, 4, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000].first { $0 * 5 >= hours } ?? (hours / 5).rounded(.up)
        return (step * 3600, max(1, Int((hours / step).rounded(.up))))
    }

    private static func tick(_ seconds: TimeInterval) -> String {
        if seconds == 0 { return "0" }
        return seconds.truncatingRemainder(dividingBy: 3600) == 0 ? "\(Int(seconds / 3600))h" : Fmt.duration(seconds, seconds: false)
    }

    private func chart(_ buckets: [Bucket], goal: TimeInterval?) -> some View {
        // Room above the bar in progress for its time (18 pt) and above the goal line for its label (22 pt).
        let current = buckets.last(where: \.current)?.seconds ?? 0
        let height = Double(Self.plotHeight)
        let (step, ticks) = Self.scale(max(buckets.map(\.seconds).max() ?? 0, current / (1 - 18 / height), (goal ?? 0) / (1 - 22 / height)))
        return HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ForEach(0...ticks, id: \.self) { i in
                    Text(Self.tick(step * Double(i))).font(WP.font(11)).monospacedDigit().foregroundStyle(WP.caption)
                        .frame(height: 14)
                        .offset(y: Self.plotHeight * (1 - CGFloat(i) / CGFloat(ticks)) - 7)
                }
            }
            .frame(minWidth: 28, alignment: .trailing)
            .frame(height: Self.plotHeight, alignment: .top)
            .accessibilityHidden(true)
            GeometryReader { geo in
                plot(buckets, width: geo.size.width, top: step * Double(ticks), ticks: ticks, goal: goal)
            }
            .frame(height: Self.plotHeight + 8 + Self.labelHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bar chart. Hours of work for each \(unit)." + (goal.map { " Daily goal \(Fmt.duration($0))." } ?? ""))
    }

    private func plot(_ buckets: [Bucket], width: CGFloat, top: TimeInterval, ticks: Int, goal: TimeInterval?) -> some View {
        // 4 pt at each end of the bars and half a gap in each slot: 8 pt at both ends, as between two bars.
        let slot = max(Self.minSlot, (width - 8) / CGFloat(buckets.count))
        let barWidth = min(96, max(1, slot - min(8, slot * 0.3)))
        let total = slot * CGFloat(buckets.count)
        return ZStack(alignment: .topLeading) {
            ForEach(0...ticks, id: \.self) { i in
                Rectangle().fill(i == 0 ? WP.border.opacity(0.55) : WP.hairline).frame(height: 1)
                    .offset(y: Self.plotHeight * (1 - CGFloat(i) / CGFloat(ticks)))
            }
            .accessibilityHidden(true)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(buckets) { bucket in
                        column(bucket, slot: slot, barWidth: barWidth, top: top)
                    }
                }
                .frame(width: total, height: Self.plotHeight + 8 + Self.labelHeight, alignment: .topLeading)
                // One stack with an alignment: without it the texts are centred on the widest text, not on their bars.
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) { texts(buckets, slot: slot, total: total, top: top) }
                }
                .padding(.horizontal, 4)
            }
            .defaultScrollAnchor(.trailing)   // the latest bars first
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollIndicatorsFlash(onAppear: true)
            .id("\(granularity.rawValue) \(data.range.lowerBound.index) \(data.range.upperBound.index)")
            if let goal {
                let y = Self.plotHeight * CGFloat(1 - goal / top)
                // The label is at the right end of the line. It goes to the left end when the time
                // above the bar in progress is in its place.
                let clash = buckets.indices.last { buckets[$0].current && buckets[$0].seconds > 0 }.map { index in
                    let barTop = Self.plotHeight * CGFloat(1 - buckets[index].seconds / top)
                    return (CGFloat(buckets.count - index) - 0.5) * slot < 120 && barTop - 20 < y - 4 && y - 24 < barTop - 2
                } ?? false
                goalLine(goal, y: y, width: width, leading: clash)
            }
        }
    }

    private func column(_ bucket: Bucket, slot: CGFloat, barWidth: CGFloat, top: TimeInterval) -> some View {
        let height = bucket.seconds > 0 ? max(2, Self.plotHeight * CGFloat(bucket.seconds / top)) : 0
        return bar(current: bucket.current, radius: min(6, barWidth / 2))
            .frame(width: barWidth, height: height)
            .frame(width: slot, height: Self.plotHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .help("\(bucket.name): \(bucket.seconds > 0 ? Fmt.duration(bucket.seconds) : "no work")")
            .accessibilityElement()
            .accessibilityLabel(bucket.name + (bucket.current ? ", so far" : ""))
            .accessibilityValue(bucket.seconds > 0 ? Fmt.duration(bucket.seconds) : "No work")
    }

    /// A complete period is solid. The period in progress has stripes and an outline.
    @ViewBuilder private func bar(current: Bool, radius: CGFloat) -> some View {
        let low = min(2, radius)
        let shape = UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: low,
                                           bottomTrailingRadius: low, topTrailingRadius: radius, style: .continuous)
        if current {
            shape.fill(WP.cobalt.opacity(0.08))
                .overlay { Hatch(color: WP.cobalt.opacity(0.3), width: 5, gap: 4).clipShape(shape) }
                .overlay { shape.strokeBorder(WP.cobalt, lineWidth: 2) }
        } else {
            shape.fill(WP.cobalt)
        }
    }

    /// The labels below the bars and the time above the bar in progress.
    @ViewBuilder private func texts(_ buckets: [Bucket], slot: CGFloat, total: CGFloat, top: TimeInterval) -> some View {
        ForEach(axisLabels(buckets, slot: slot, total: total)) { label in
            VStack(spacing: 0) {
                Text(label.top).font(WP.font(12, label.current ? .bold : label.muted ? .medium : .semibold))
                    .foregroundStyle(label.current ? WP.textBlue : label.muted ? WP.secondary : WP.ink)
                Text(label.bottom).font(WP.font(11, label.current ? .bold : .regular))
                    .foregroundStyle(label.current ? WP.textBlue : WP.secondary)
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .frame(width: label.width)
            .offset(x: label.x, y: Self.plotHeight + 8)
            .accessibilityHidden(true)
        }
        if let index = buckets.lastIndex(where: \.current), buckets[index].seconds > 0 {
            let text = Fmt.duration(buckets[index].seconds)
            let width = CGFloat(text.count) * 7 + 8
            Text(text).font(WP.font(11, .bold)).monospacedDigit().foregroundStyle(WP.ink).lineLimit(1)
                .frame(width: width)
                .offset(x: Self.place(center: (CGFloat(index) + 0.5) * slot, width: width, total: total),
                        y: Self.plotHeight * CGFloat(1 - buckets[index].seconds / top) - 18)
                .accessibilityHidden(true)
        }
    }

    /// The left edge of a text that is centred on `center` but stays inside the chart.
    private static func place(center: CGFloat, width: CGFloat, total: CGFloat) -> CGFloat {
        min(max(0, center - width / 2), max(0, total - width))
    }

    /// As many labels as fit without overlap. The label of the period in progress goes first.
    private func axisLabels(_ buckets: [Bucket], slot: CGFloat, total: CGFloat) -> [AxisLabel] {
        var placed: [AxisLabel] = []
        let order = buckets.indices.filter { buckets[$0].current } + buckets.indices.filter { !buckets[$0].current }
        for index in order where !buckets[index].top.isEmpty {
            let bucket = buckets[index]
            var label = AxisLabel(id: bucket.id, top: bucket.top, bottom: bucket.bottom, current: bucket.current, muted: bucket.muted)
            label.x = Self.place(center: (CGFloat(index) + 0.5) * slot, width: label.width, total: total)
            if !placed.contains(where: { $0.x < label.x + label.width && label.x < $0.x + $0.width }) { placed.append(label) }
        }
        return placed
    }

    /// The daily goal: a dashed line with its value in words.
    @ViewBuilder private func goalLine(_ goal: TimeInterval, y: CGFloat, width: CGFloat, leading: Bool) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
        }
        .stroke(WP.ink, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        Text("Goal \(Fmt.duration(goal))").font(WP.font(11, .semibold)).monospacedDigit().foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .background(WP.navy, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: width, alignment: leading ? .leading : .trailing)
            .offset(y: y - 22)
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // the chart label says the goal
    }

    private func legend(current: Bool, goal: Bool) -> some View {
        HStack(spacing: 18) {
            legendItem("Work, \(unit) complete") { bar(current: false, radius: 3).frame(width: 12, height: 12) }
            if current {
                legendItem(granularity == .day ? "Work, today so far" : "Work, this \(unit) so far") {
                    bar(current: true, radius: 3).frame(width: 12, height: 12)
                }
            }
            if goal {
                legendItem("Daily goal") {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 6))
                        path.addLine(to: CGPoint(x: 16, y: 6))
                    }
                    .stroke(WP.ink, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: 16, height: 12)
                }
            }
        }
    }

    private func legendItem(_ text: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 6) {
            swatch().accessibilityHidden(true)
            Text(text).font(WP.font(12)).foregroundStyle(WP.secondary)
        }
    }

    // MARK: Applications and goals

    /// The two cards are side by side only when their heights are almost the same:
    /// a short card beside a long card leaves an empty area.
    private var balanced: Bool {
        // ponytail: heights are estimates from the row counts; measure the cards if the rows change.
        let apps = 79 + 48 * max(1, appRows.count), goals = 133 + 37 * goalRows.count
        return abs(apps - goals) <= 80
    }

    private var stacked: some View {
        VStack(spacing: 16) { applications; goalHistory }
    }

    /// The seven applications with the most work; the others are one row.
    private var appRows: [(key: String, seconds: TimeInterval)] {
        let rest = data.apps.dropFirst(7).reduce(0) { $0 + $1.seconds }
        return Array(data.apps.prefix(7)) + (rest > 0 ? [(key: "Other applications", seconds: rest)] : [])
    }

    private var applications: some View {
        let total = data.apps.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle("By application")
            if total > 0 {
                ForEach(Array(appRows.enumerated()), id: \.offset) { _, row in
                    let percent = Int((row.seconds / total * 100).rounded())
                    VStack(spacing: 6) {
                        HStack(alignment: .center, spacing: 8) {
                            AppTile(name: row.key, bundleID: data.appIDs[row.key],
                                    symbol: row.key == "Other applications" ? "square.grid.2x2" : row.key == "Manual entry" ? "pencil" : nil, size: 20)
                            Text(row.key).font(WP.font(13, .semibold)).foregroundStyle(WP.ink).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(Fmt.duration(row.seconds)) · \(percent)%").font(WP.font(13)).monospacedDigit()
                                .foregroundStyle(WP.secondary).fixedSize()
                        }
                        WPBar(fraction: row.seconds / total, label: row.key)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.key)
                    .accessibilityValue("\(Fmt.duration(row.seconds)), \(percent) percent")
                }
                // At the bottom of the card: on one line with the note of the goal card beside it.
                Text("Total \(Fmt.duration(total)) of work").font(WP.font(12)).monospacedDigit().foregroundStyle(WP.caption)
                    .frame(maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                emptyText("No work is recorded for this period.")
            }
        }
        .frame(minWidth: 308, idealWidth: 308, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // 340 with the card padding
        .wpCard(strong: true)
    }

    private var goalRows: [PeriodResult] { Array((goalPeriod == .week ? data.weeks : data.months).suffix(12)) }

    private var goalHistory: some View {
        let count = (goalPeriod == .week ? data.weeks : data.months).count
        let rows = goalRows
        let segments = Segments(label: "Period", options: [("Weeks", Period.week), ("Months", Period.month)], selection: $goalPeriod)
        return VStack(alignment: .leading, spacing: 12) {
            heading("Goal achievement", control: segments)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        columnTitle(goalPeriod == .week ? "Week" : "Month").frame(maxWidth: .infinity, alignment: .leading)
                        columnTitle("Work").gridColumnAlignment(.trailing)
                        columnTitle("Goal").gridColumnAlignment(.trailing)
                        columnTitle("Days").gridColumnAlignment(.trailing)
                        columnTitle("Result")
                    }
                    ForEach(rows, id: \.range.lowerBound) { row in
                        rowLine
                        GridRow {
                            Text(periodTitle(row)).font(WP.font(13, .semibold)).lineLimit(1).padding(.vertical, 10)
                            Text(Fmt.duration(row.workSeconds)).accessibilityLabel("Work \(Fmt.duration(row.workSeconds))")
                            Text(row.targetSeconds.map { Fmt.duration($0) } ?? "–")
                                .accessibilityLabel(row.targetSeconds.map { "Goal \(Fmt.duration($0))" } ?? "No goal")
                            Text(days(row)).accessibilityLabel("Working days \(days(row))")
                            result(row).accessibilityElement(children: .combine)
                        }
                        .font(WP.font(13)).monospacedDigit().foregroundStyle(WP.ink)
                    }
                }
                // The table is as wide as the card. In a narrow card it scrolls sideways.
                .containerRelativeFrame(.horizontal) { width, _ in max(width, 420) }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if count > rows.count {
                note("The table shows the latest \(rows.count) of \(count) \(goalPeriod == .week ? "weeks" : "months").")
            }
            note("Each period uses the goals that applied at that time.")
        }
        // Wide enough for all five columns, so the Result column is never cut.
        .frame(minWidth: 420, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .wpCard(strong: true)
    }

    private func periodTitle(_ row: PeriodResult) -> String {
        if row.period == .week { return span(row.range, year: year == 0) }
        let c = row.range.lowerBound.components
        return "\(Calendar.current.shortMonthSymbols[c.month - 1]) \(c.year)"
    }

    /// Working days of the period and its number of work days: "4 of 5".
    private func days(_ row: PeriodResult) -> String {
        let config = Goals.config(on: min(row.range.upperBound, .today()), projectID: nil, in: model.goals)
        let target = row.daysTarget ?? config.map { config in row.range.days.filter { config.workingDays.contains($0.weekday) && !model.isDayOff($0) }.count }
        return target.map { "\(row.workingDays) of \($0)" } ?? String(row.workingDays)
    }

    /// An icon and a word for each result, so the result never depends on colour.
    private func result(_ row: PeriodResult) -> some View {
        let (symbol, text, tint, ink): (String, String, Color, Color) = switch row.achieved {
        case true?: ("checkmark.circle.fill", "Reached", WP.green, WP.greenInk)
        case false? where row.range.upperBound >= .today(): ("clock", "In progress", WP.textBlue, WP.textBlue)
        case false?: ("xmark.circle", "Missed", WP.secondary, WP.secondary)
        case nil: ("minus.circle", "No goal", WP.caption, WP.caption)
        }
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(WP.font(13, .semibold)).foregroundStyle(ink).fixedSize()
        }
    }

    // MARK: Compensation

    /// The hourly rate of the whole period, in the latest currency.
    private var payRate: (value: String, detail: String)? {
        guard let currency = data.pay.last?.currency else { return nil }
        let rows = data.pay.filter { $0.currency == currency }
        let amount = rows.reduce(0) { $0 + $1.amount }, work = rows.reduce(0) { $0 + $1.work }
        guard let hourly = Pay.hourly(monthlyAmount: amount, workSeconds: work) else { return ("–", "No work is recorded for this period.") }
        return (hourly.formatted(.currency(code: currency)), "\(amount.formatted(.currency(code: currency))) for \(Fmt.duration(work)) of work")
    }

    private var compensation: some View {
        let rows = Array(data.pay.suffix(12))
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Compensation")
            if let rate = payRate {
                VStack(alignment: .leading, spacing: 2) {
                    FieldLabel("Effective hourly rate")
                    Text(rate.value).font(WP.font(20, .bold)).monospacedDigit().foregroundStyle(WP.ink)
                    Text(rate.detail).font(WP.font(12)).monospacedDigit().foregroundStyle(WP.caption)
                }
                .accessibilityElement(children: .combine)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    columnTitle("Month").frame(maxWidth: .infinity, alignment: .leading)
                    columnTitle("Amount").gridColumnAlignment(.trailing)
                    columnTitle("Work").gridColumnAlignment(.trailing)
                    columnTitle("Per hour").gridColumnAlignment(.trailing)
                }
                ForEach(rows) { row in
                    rowLine
                    GridRow {
                        Text("\(Calendar.current.shortMonthSymbols[row.month.components.month - 1]) \(String(row.month.components.year))")
                            .font(WP.font(13, .semibold)).lineLimit(1).padding(.vertical, 10)
                        Text(row.amount.formatted(.currency(code: row.currency)))
                            .accessibilityLabel("Amount \(row.amount.formatted(.currency(code: row.currency)))")
                        Text(Fmt.duration(row.work)).accessibilityLabel("Work \(Fmt.duration(row.work))")
                        Text(row.hourly.map { $0.formatted(.currency(code: row.currency)) } ?? "–")
                            .accessibilityLabel(row.hourly.map { "Per hour \($0.formatted(.currency(code: row.currency)))" } ?? "No hourly rate")
                    }
                    .font(WP.font(13)).monospacedDigit().foregroundStyle(WP.ink)
                }
            }
            if data.pay.count > rows.count { note("The table shows the latest \(rows.count) of \(data.pay.count) months.") }
            note("WorkPulse divides the monthly amount by the hours of work. The current month uses the hours so far.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wpCard(strong: true)
    }

    // MARK: Parts

    /// A card title with a control: on one line, or the control below the title in a narrow card.
    private func heading(_ title: String, _ subtitle: String? = nil, control: some View) -> some View {
        let titles = VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title)
            if let subtitle { Text(subtitle).font(WP.font(12)).foregroundStyle(WP.caption) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { titles; Spacer(minLength: 0); control }
            VStack(alignment: .leading, spacing: 10) { titles; control }
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text).font(WP.font(12, .medium)).foregroundStyle(WP.caption).padding(.vertical, 6)
    }

    private var rowLine: some View {
        Rectangle().fill(WP.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal).accessibilityHidden(true)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(WP.font(12)).foregroundStyle(WP.caption).fixedSize(horizontal: false, vertical: true)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).font(WP.font(13)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A choice between a few options. A check mark shows the selected option, so the state never depends on colour.
private struct Segments<Value: Hashable>: View {
    let label: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    // All segments have the width of the widest selected state: the columns are equal
                    // and the control does not change size.
                    ZStack {
                        ForEach(options, id: \.value) { checked($0.title).hidden() }
                        if on { checked(option.title) } else {
                            Text(option.title).font(WP.font(13, .medium)).foregroundStyle(WP.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WP.field)
                                .shadow(color: WP.navy.opacity(0.2), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(WP.track, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func checked(_ title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
            Text(title).font(WP.font(13, .semibold))
        }
        .foregroundStyle(WP.ink)
    }
}
