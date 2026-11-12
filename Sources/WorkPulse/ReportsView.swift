import Charts
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

private struct Bucket: Identifiable {
    let start: LocalDay
    let seconds: TimeInterval
    var id: Int { start.index }
}

private struct ReportData {
    var range = LocalDay.today()...LocalDay.today()
    var sessions: [Session] = []
    var totals: [LocalDay: DayTotals] = [:]
    var stats = RangeStats()
    var previous: RangeStats?
    var apps: [(key: String, seconds: TimeInterval)] = []
    var categories: [(key: String, seconds: TimeInterval)] = []
    var projects: [(key: String, seconds: TimeInterval)] = []
    var weeks: [PeriodResult] = []
    var months: [PeriodResult] = []
    var pay: [PayRow] = []
}

/// Analytics for any month, any year, or all time: totals, trends, calendar, distributions,
/// goal history and effective hourly compensation.
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var year = LocalDay.today().components.year  // 0 = all time
    @State private var month = LocalDay.today().components.month  // 0 = whole year
    @State private var granularity = Period.day
    @State private var goalPeriod = Period.week
    @State private var years: [Int] = []
    @State private var data = ReportData()

    private var query: [AnyHashable] { [year, month, model.revision] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                tiles
                GroupBox { trend.padding(6) }
                GroupBox { calendar.padding(6) }
                HStack(alignment: .top, spacing: 12) {
                    DistributionList(title: "By application", rows: data.apps)
                    DistributionList(title: "By category", rows: data.categories)
                    DistributionList(title: "By project (work)", rows: data.projects)
                }
                HStack(alignment: .top, spacing: 12) {
                    GroupBox { goalHistory.padding(6) }
                    if !data.pay.isEmpty { GroupBox { compensation.padding(6) } }
                }
            }
            .padding(4)
        }
        .onChange(of: query, initial: true) { load() }
    }

    // MARK: Data

    private func load() {
        let today = LocalDay.today()
        let first = min((try? model.store.firstDay()) ?? today, today)
        years = Array(first.components.year...today.components.year).reversed()

        let range: ClosedRange<LocalDay>
        var previousRange: ClosedRange<LocalDay>?
        if year == 0 {
            range = first...today
        } else if month == 0 {
            range = LocalDay(year: year, month: 1, day: 1)...LocalDay(year: year, month: 12, day: 31)
            previousRange = LocalDay(year: year - 1, month: 1, day: 1)...LocalDay(year: year - 1, month: 12, day: 31)
        } else {
            let start = LocalDay(year: year, month: month, day: 1)
            range = start...start.monthEnd
            previousRange = start.adding(-1).monthStart...start.adding(-1)
        }

        let firstWeekday = model.settings.firstWeekday
        // Padded so weeks that straddle the range edges are evaluated on their full seven days.
        let sessions = (try? model.store.sessions(days: range.lowerBound.adding(-7)...range.upperBound.adding(7))) ?? []
        var d = ReportData()
        d.range = range
        d.totals = Aggregator.dayTotals(sessions)
        d.sessions = sessions.filter { s in Aggregator.split(s).contains { range.contains($0.day) } }
        d.stats = Aggregator.stats(d.totals, in: range, configs: model.goals)
        if let previousRange {
            d.previous = Aggregator.stats(model.totals(days: previousRange), in: previousRange, configs: model.goals)
        }
        d.apps = Aggregator.distribution(sessions, in: range, kinds: [.work, .nonwork]) { $0.appName ?? "Manual entry" }
        d.categories = Aggregator.distribution(sessions, in: range, kinds: [.work, .nonwork]) { model.categoryName($0) }
        d.projects = Aggregator.distribution(sessions, in: range, kinds: [.work]) { model.projectName($0.projectID) }
        if range.lowerBound <= today {
            let past = range.lowerBound...min(range.upperBound, today)
            d.weeks = Goals.history(.week, in: past, totals: d.totals, configs: model.goals, today: today, firstWeekday: firstWeekday)
            d.months = Goals.history(.month, in: past, totals: d.totals, configs: model.goals, today: today, firstWeekday: firstWeekday)
            d.pay = d.months.compactMap { m in
                Pay.entry(on: min(m.range.upperBound, today), in: model.pay).map {
                    PayRow(month: m.range.lowerBound, amount: $0.monthlyAmount, currency: $0.currency, work: m.workSeconds)
                }
            }
        }
        data = d
    }

    private var title: String {
        if year == 0 { return "All time" }
        return month == 0 ? String(year) : Fmt.day(LocalDay(year: year, month: month, day: 1), "MMMMyyyy")
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Spacer()
            Picker("Year", selection: $year) {
                Text("All time").tag(0)
                ForEach(years, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker("Month", selection: $month) {
                Text("Whole year").tag(0)
                ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
            }
            .labelsHidden().fixedSize().disabled(year == 0)
            Button("Export Sessions…") {
                let categories = Dictionary(uniqueKeysWithValues: model.categories.map { ($0.id, $0.name) })
                let projects = Dictionary(uniqueKeysWithValues: model.projects.map { ($0.id, $0.name) })
                model.export(CSV.sessions(data.sessions, categories: categories, projects: projects), name: "workpulse-sessions.csv")
            }
            Button("Export Daily Summary…") {
                let csv = CSV.daily(data.totals, in: data.range) { day, work in Goals.isWorkingDay(work, on: day, configs: model.goals) }
                model.export(csv, name: "workpulse-daily-summary.csv")
            }
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            tile("Tracked work", Fmt.hours(data.stats.work), comparison)
            tile("Working days", String(data.stats.workingDays), data.previous.map { "previous period: \($0.workingDays)" })
            tile("Average per working day", Fmt.duration(data.stats.averagePerWorkingDay),
                 data.previous.map { "previous period: \(Fmt.duration($0.averagePerWorkingDay))" })
            tile("Active application time", Fmt.hours(data.stats.active),
                 "idle \(Fmt.duration(data.stats.idle)) · excluded \(Fmt.duration(data.stats.excluded))")
            tile("Goal completion", goalCompletion.value, goalCompletion.detail)
            if let pay = payTile { tile("Effective hourly rate", pay.value, pay.detail) }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var comparison: String? {
        guard let previous = data.previous else { return nil }
        guard previous.work >= 60 else { return "no data for the previous period" }
        let change = (data.stats.work - previous.work) / previous.work * 100
        return String(format: "%+.0f%% vs previous (%@)", change, Fmt.hours(previous.work))
    }

    private var goalCompletion: (value: String, detail: String?) {
        let weeks = data.weeks.compactMap(\.achieved), months = data.months.compactMap(\.achieved)
        guard !weeks.isEmpty || !months.isEmpty else { return ("—", "no goals applied to this period") }
        let weekText = weeks.isEmpty ? nil : "\(weeks.filter { $0 }.count) of \(weeks.count) weeks"
        let monthText = months.isEmpty ? nil : "\(months.filter { $0 }.count) of \(months.count) months"
        return (weekText ?? monthText ?? "—", weekText == nil ? nil : monthText)
    }

    private var payTile: (value: String, detail: String?)? {
        guard let currency = data.pay.last?.currency else { return nil }
        let rows = data.pay.filter { $0.currency == currency }
        let amount = rows.reduce(0) { $0 + $1.amount }, work = rows.reduce(0) { $0 + $1.work }
        guard let hourly = Pay.hourly(monthlyAmount: amount, workSeconds: work) else { return ("—", "no work recorded") }
        return (hourly.formatted(.currency(code: currency)), "\(amount.formatted(.currency(code: currency))) over \(Fmt.hours(work))")
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Work trend").font(.headline)
                Spacer()
                Picker("Granularity", selection: $granularity) {
                    Text("Daily").tag(Period.day)
                    Text("Weekly").tag(Period.week)
                    Text("Monthly").tag(Period.month)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            let unit: Calendar.Component = granularity == .day ? .day : granularity == .week ? .weekOfYear : .month
            let buckets = Aggregator.trend(data.totals, in: data.range, by: granularity, firstWeekday: model.settings.firstWeekday)
                .map { Bucket(start: $0.start, seconds: $0.seconds) }
            Chart(buckets) { bucket in
                BarMark(x: .value("Period", bucket.start.localNoon(), unit: unit), y: .value("Hours", bucket.seconds / 3600))
            }
            .chartYAxisLabel("hours of work")
            .frame(height: 170)
        }
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity calendar").font(.headline)
                Spacer()
                Text("Less").font(.caption).foregroundStyle(.secondary)
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(MonthGrid.color(level)).frame(width: 11, height: 11)
                }
                Text("More").font(.caption).foregroundStyle(.secondary)
            }
            let peak = max(3600, data.range.days.map { data.totals[$0]?.work ?? 0 }.max() ?? 0)
            let months = Aggregator.trend(data.totals, in: data.range, by: .month, firstWeekday: 1).map(\.start)
            if months.count == 1, let only = months.first {
                MonthGrid(month: only, totals: data.totals, peak: peak, firstWeekday: model.settings.firstWeekday, compact: false)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 14, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(months, id: \.index) { month in
                        MonthGrid(month: month, totals: data.totals, peak: peak, firstWeekday: model.settings.firstWeekday, compact: true)
                    }
                }
            }
        }
    }

    private var goalHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Goal achievement").font(.headline)
                Spacer()
                Picker("Period", selection: $goalPeriod) {
                    Text("Weeks").tag(Period.week)
                    Text("Months").tag(Period.month)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            let all = goalPeriod == .week ? data.weeks : data.months
            let rows = Array(all.reversed().prefix(12))
            if rows.isEmpty {
                Text("No data").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text(goalPeriod == .week ? "Week of" : "Month")
                        Text("Work")
                        Text("Target")
                        Text("Days")
                        Text("Result")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(rows, id: \.range.lowerBound) { r in
                        GridRow {
                            Text(Fmt.day(r.range.lowerBound, goalPeriod == .week ? "dMMMyyyy" : "MMMyyyy"))
                            Text(Fmt.duration(r.workSeconds)).monospacedDigit()
                            Text(r.targetSeconds.map { Fmt.duration($0) } ?? "—").monospacedDigit()
                            Text(r.daysTarget.map { "\(r.workingDays) of \($0)" } ?? "\(r.workingDays)").monospacedDigit()
                            switch r.achieved {
                            case true?: Label("Reached", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            case false?: Label("Missed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                            case nil: Text("No goal").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if all.count > rows.count {
                    Text("Showing the latest \(rows.count) of \(all.count).").font(.caption).foregroundStyle(.secondary)
                }
                Text("Each period is judged by the goals that applied at the time.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compensation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compensation").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Month")
                    Text("Amount")
                    Text("Work")
                    Text("Per hour")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(data.pay.reversed().prefix(12))) { row in
                    GridRow {
                        Text(Fmt.day(row.month, "MMMyyyy"))
                        Text(row.amount.formatted(.currency(code: row.currency))).monospacedDigit()
                        Text(Fmt.hours(row.work)).monospacedDigit()
                        Text(row.hourly.map { $0.formatted(.currency(code: row.currency)) } ?? "—").monospacedDigit()
                    }
                }
            }
            Text("Monthly amount divided by hours worked. The current month counts hours so far.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A month as a 7-column grid; cell colour shows how much work was recorded that day.
struct MonthGrid: View {
    let month: LocalDay
    let totals: [LocalDay: DayTotals]
    let peak: TimeInterval
    let firstWeekday: Int
    let compact: Bool

    static func color(_ level: Double) -> Color {
        level <= 0 ? Color.secondary.opacity(0.14) : Color.accentColor.opacity(0.25 + 0.75 * min(1, level))
    }

    var body: some View {
        let size: CGFloat = compact ? 14 : 34
        let lead = (month.monthStart.weekday - firstWeekday + 7) % 7
        let cells: [LocalDay?] = Array(repeating: nil, count: lead) + (month.monthStart...month.monthEnd).days.map { $0 }
        let columns = Array(repeating: GridItem(.fixed(size), spacing: 3), count: 7)
        VStack(alignment: .leading, spacing: 4) {
            Text(Fmt.day(month, compact ? "MMMyyyy" : "MMMMyyyy")).font(compact ? .caption : .subheadline)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                if !compact {
                    ForEach(0..<7, id: \.self) { i in
                        Text(Calendar.current.veryShortWeekdaySymbols[(firstWeekday - 1 + i) % 7])
                            .font(.caption2).foregroundStyle(.secondary).frame(width: size)
                    }
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let work = totals[day]?.work ?? 0
                        RoundedRectangle(cornerRadius: compact ? 2 : 5)
                            .fill(Self.color(work / peak))
                            .frame(width: size, height: size)
                            .overlay {
                                if !compact { Text(String(day.components.day)).font(.caption2) }
                            }
                            .help("\(Fmt.day(day)): \(work > 0 ? Fmt.duration(work) : "no work recorded")")
                    } else {
                        Color.clear.frame(width: size, height: size)
                    }
                }
            }
        }
    }
}

struct DistributionList: View {
    let title: String
    let rows: [(key: String, seconds: TimeInterval)]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                let total = rows.reduce(0) { $0 + $1.seconds }
                // Top seven, everything else folded into "Other".
                let top = Array(rows.prefix(7))
                let rest = rows.dropFirst(7).reduce(0) { $0 + $1.seconds }
                let shown = rest > 0 ? top + [(key: "Other", seconds: rest)] : top
                if shown.isEmpty { Text("No data").foregroundStyle(.secondary) }
                ForEach(shown, id: \.key) { row in
                    VStack(spacing: 2) {
                        HStack {
                            Text(row.key).lineLimit(1)
                            Spacer()
                            Text("\(Fmt.duration(row.seconds)) · \(Int((row.seconds / max(1, total) * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        ProgressView(value: total > 0 ? row.seconds / total : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}
