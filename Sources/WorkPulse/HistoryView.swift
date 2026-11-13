import SwiftUI
import WorkPulseCore

/// Sessions by day, week, month, custom range or all time. Select a session to correct it.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    enum Scope: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week", month = "Month", custom = "Custom", all = "All"
        var id: String { rawValue }
    }

    @State private var scope = Scope.day
    @State private var anchor = Date()
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var search = ""
    @State private var kind: SessionKind?
    /// Oldest first, as a timeline.
    @State private var sessions: [Session] = []
    @State private var days: [(day: LocalDay, sessions: [Session])] = []
    @State private var totals = DayTotals()
    /// The session that is still open (the engine has not closed it).
    @State private var liveID: Int64?
    /// The session in the edit panel. Its row is the selected row.
    @State private var editing: Session?
    /// True when the table and the edit panel fit side by side.
    @State private var wide = true
    @FocusState private var listFocused: Bool

    private var range: ClosedRange<LocalDay>? {
        switch scope {
        case .day:
            let day = LocalDay.today(anchor)
            return day...day
        case .week: return Period.week.range(containing: .today(anchor), firstWeekday: model.settings.firstWeekday)
        case .month: return Period.month.range(containing: .today(anchor), firstWeekday: model.settings.firstWeekday)
        case .custom:
            let a = LocalDay.today(from), b = LocalDay.today(to)
            return min(a, b)...max(a, b)
        case .all: return nil
        }
    }

    private var query: [AnyHashable] { [scope, anchor, from, to, search, kind, model.revision] }

    var body: some View {
        Screen {
            ScrollViewReader { page in
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(title: "History", subtitle: "See your sessions and correct them.") {
                        HStack(spacing: 8) {
                            Button(action: newSession) { Label("Add Session…", systemImage: "plus") }
                                .help("Add a session that WorkPulse did not record")
                            Button(action: exportCSV) { Label("Export CSV…", systemImage: "arrow.down.to.line") }
                                .disabled(sessions.isEmpty)
                        }
                        .buttonStyle(WPButtonStyle())
                    }
                    filters.wpRise(0)
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
                    layout {
                        table.frame(maxWidth: .infinity).wpRise(1)
                        if let editing {
                            SessionEditor(session: editing) { self.editing = nil }
                                .id(editing.id)   // a different session starts a new draft
                                .frame(maxWidth: wide ? 320 : .infinity)
                                .wpRise(2)
                                .id("editor")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)   // side by side, the table card is as high as the panel
                    .onGeometryChange(for: Bool.self) { $0.size.width >= 756 } action: { wide = $0 }
                }
                .onChange(of: editing?.id) {
                    // Below the table, the panel can be out of view: bring it into view.
                    guard editing != nil, !wide else { return }
                    Task { withAnimation { page.scrollTo("editor") } }
                }
            }
        }
        .onChange(of: query, initial: true) { load() }
    }

    // MARK: Data

    private func load() {
        do {
            let kinds = kind.map { Set([$0]) }
            let found = try range.map { try model.store.sessions(days: $0, search: search, kinds: kinds) }
                ?? model.store.sessions(search: search, kinds: kinds)
            sessions = found
            days = Dictionary(grouping: found) { LocalDay(date: $0.start, tzOffset: $0.tzOffset) }
                .sorted { $0.key < $1.key }.map { (day: $0.key, sessions: $0.value) }
            totals = Aggregator.sum(Aggregator.dayTotals(found), in: range)
            // An open session has no end reason and the latest end of all sessions.
            let latest = try model.store.latestEnd()
            liveID = found.last.flatMap { $0.endReason.isEmpty && $0.end == latest ? $0.id : nil }
            if let id = editing?.id, id != 0, !found.contains(where: { $0.id == id }) { editing = nil }
        } catch {
            model.banner = error.localizedDescription
        }
    }

    private func shift(_ direction: Int) {
        let unit: Calendar.Component = scope == .day ? .day : scope == .week ? .weekOfYear : .month
        anchor = min(Date(), Calendar.current.date(byAdding: unit, value: direction, to: anchor) ?? anchor)
    }

    private func newSession() {
        let now = Date()
        editing = Session(start: now.addingTimeInterval(-3600), end: now, tzOffset: TimeZone.current.secondsFromGMT(for: now),
                          kind: .work, categoryID: Store.workID, projectID: nil, source: .entry, endReason: "manual")
    }

    private func exportCSV() {
        let categories = Dictionary(uniqueKeysWithValues: model.categories.map { ($0.id, $0.name) })
        model.export(CSV.sessions(sessions, categories: categories, projects: [:]), name: "workpulse-sessions.csv")
    }

    /// Arrow keys move the selection through the list.
    private func move(_ step: Int) {
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == editing?.id }
        let next = current.map { min(max($0 + step, 0), sessions.count - 1) } ?? (step > 0 ? 0 : sessions.count - 1)
        editing = sessions[next]
    }

    // MARK: Filters

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) { pickers; searchField }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) { pickers }
                searchField
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    @ViewBuilder private var pickers: some View {
        HistoryField(label: "Range") {
            Picker("Range", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().controlSize(.large).frame(width: 112)
        }
        if scope == .custom {
            dateField("From", $from)
            dateField("To", $to)
        } else if scope != .all {
            let unit = scope.rawValue.lowercased()
            HStack(alignment: .bottom, spacing: 4) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(WPButtonStyle())
                    .accessibilityLabel("Previous \(unit)").help("Previous \(unit)")
                dateField("Date", $anchor)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(WPButtonStyle())
                    .disabled(range.map { $0.upperBound >= .today() } ?? true)
                    .accessibilityLabel("Next \(unit)").help("Next \(unit)")
            }
            Button("Today") { anchor = Date() }.buttonStyle(WPButtonStyle())
        }
        HistoryField(label: "Type") {
            Picker("Type", selection: $kind) {
                Text("All types").tag(SessionKind?.none)
                ForEach(SessionKind.allCases, id: \.self) { Text(HistoryText.kind($0)).tag(SessionKind?.some($0)) }
            }
            .labelsHidden().controlSize(.large).frame(width: 132)
        }
    }

    private func dateField(_ label: String, _ date: Binding<Date>) -> some View {
        HistoryField(label: label) {
            DatePicker(label, selection: date, in: ...Date(), displayedComponents: .date)
                .labelsHidden().controlSize(.large).fixedSize()
        }
    }

    private var searchField: some View {
        HistoryField(label: "Search") {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(WP.caption).accessibilityHidden(true)
                TextField("Application, note, category", text: $search)
                    .textFieldStyle(.plain).font(WP.font(13)).foregroundStyle(WP.ink)
                    .accessibilityLabel("Search")
            }
            .wpField()
        }
        .frame(minWidth: 140, idealWidth: 220, maxWidth: .infinity)
    }

    // MARK: Table

    private var hairline: some View { Rectangle().fill(WP.hairline).frame(height: 1) }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Start").frame(width: HistoryRow.start, alignment: .leading)
                Text("End").frame(width: HistoryRow.end, alignment: .leading)
                Text("Duration").frame(width: HistoryRow.duration, alignment: .trailing)
                Text("Type").padding(.leading, 20).frame(width: HistoryRow.type, alignment: .leading)
                Text("Application").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(WP.font(12, .medium)).foregroundStyle(WP.caption).lineLimit(1)
            .padding(.horizontal, 16).frame(height: 36)
            .accessibilityHidden(true)   // each row says its own values
            hairline
            if sessions.isEmpty {
                Text(emptyText).font(WP.font(13)).foregroundStyle(WP.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else {
                list
            }
            Spacer(minLength: 0)   // keeps the totals at the bottom when the edit panel is higher than the rows
            footer
        }
        .wpCard(padding: 0, strong: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tableLabel)
    }

    /// The rows scroll in the card. The card is as high as its rows, up to the height of the window.
    private var list: some View {
        let headers = scope != .day || days.count > 1
        let height = CGFloat(sessions.count) * HistoryRow.height + (headers ? CGFloat(days.count) * 28 : 0) - 1
        return ScrollViewReader { rows in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(days, id: \.day) { group in
                        if headers {
                            Text(HistoryText.day(group.day)).font(WP.font(12, .semibold)).foregroundStyle(WP.secondary)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                                .background(WP.hover.opacity(0.5))
                                .overlay(alignment: .bottom) { hairline }
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(group.sessions) { session in
                            HistoryRow(session: session, live: session.id == liveID, selected: session.id == editing?.id) {
                                editing = session
                                listFocused = true
                            }
                        }
                    }
                }
                .padding(.bottom, -1)   // the footer draws the last line
            }
            .containerRelativeFrame(.vertical) { viewport, _ in min(height, max(200, viewport - 280)) }
            .focusable()
            .focused($listFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(press.key == .upArrow ? -1 : 1)
                return .handled
            }
            .onChange(of: editing?.id) { _, id in
                if let id { rows.scrollTo(id) }
            }
        }
    }

    private var footer: some View {
        let count = Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")").fontWeight(.semibold).foregroundStyle(WP.ink)
        let parts = ["Work \(Fmt.duration(totals.work))", "Applications \(Fmt.duration(totals.active))",
                     "Idle \(Fmt.duration(totals.idle))", "Ignored \(Fmt.duration(totals.excluded))"]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { count; ForEach(parts, id: \.self) { Text($0) } }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) { count; Text(parts[0]); Text(parts[1]) }
                HStack(spacing: 16) { Text(parts[2]); Text(parts[3]) }
            }
        }
        .font(WP.font(12)).monospacedDigit().foregroundStyle(WP.secondary).lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .top) { hairline }
        .accessibilityElement(children: .combine)
    }

    private var emptyText: String {
        if kind != nil || !search.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No sessions match your filters. Change the type or the search text."
        }
        switch scope {
        case .day: return "WorkPulse recorded no sessions on this day. To add one, select Add Session…"
        case .all: return "WorkPulse has no sessions yet. To add one, select Add Session…"
        default: return "WorkPulse recorded no sessions in this range. To add one, select Add Session…"
        }
    }

    private var tableLabel: String {
        guard let range else { return "All sessions" }
        return range.lowerBound == range.upperBound
            ? "Sessions on \(HistoryText.day(range.lowerBound, long: true))"
            : "Sessions from \(HistoryText.day(range.lowerBound)) to \(HistoryText.day(range.upperBound))"
    }
}

// MARK: - Parts

/// Texts that this screen and the edit panel share.
@MainActor private enum HistoryText {
    static func kind(_ kind: SessionKind) -> String { kind == .excluded ? "Ignored" : Fmt.kind(kind) }

    /// Clock time in the UTC offset of the session, the same offset that decides its day.
    static func clock(_ date: Date, _ session: Session) -> String {
        Fmt.time(minutes: Int(((date.timeIntervalSince1970 + Double(session.tzOffset)) / 60).rounded(.down)))
    }

    /// "Wed, 11 Nov", or "Wednesday, 11 November 2026".
    static func day(_ day: LocalDay, long: Bool = false) -> String {
        let format: Date.FormatString = long
            ? "\(weekday: .wide), \(day: .defaultDigits) \(month: .wide) \(year: .defaultDigits)"
            : "\(weekday: .abbreviated), \(day: .defaultDigits) \(month: .abbreviated)"
        return day.utcDate.formatted(Date.VerbatimFormatStyle(format: format, locale: .current, timeZone: .gmt,
                                                              calendar: Calendar(identifier: .gregorian)))
    }

    static func day(of session: Session) -> LocalDay { LocalDay(date: session.start, tzOffset: session.tzOffset) }
}

/// A label above a control.
private struct HistoryField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(label)
            content.frame(minHeight: 32)
        }
    }
}

/// The colour of a session type. Idle has stripes and Ignored is an outline, so the colour is never the only signal.
private struct HistorySwatch: View {
    let kind: SessionKind

    var body: some View {
        Group {
            switch kind {
            case .work: WP.cobalt
            case .nonwork: WP.switchOff
            case .idle: ZStack { WP.amber; Hatch(color: WP.amberHatch, width: 2, gap: 3) }
            case .excluded: RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(WP.caption, lineWidth: 1.5)
            }
        }
        .frame(width: 10, height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// One session in the table. A click opens it in the edit panel.
private struct HistoryRow: View {
    static let start: CGFloat = 68, end: CGFloat = 60, duration: CGFloat = 68, type: CGFloat = 116, height: CGFloat = 40

    let session: Session
    let live: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let start = HistoryText.clock(session.start, session)
        let end = HistoryText.clock(session.end, session)
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    if selected {
                        Image(systemName: "pencil").font(.system(size: 11, weight: .bold)).accessibilityLabel("Selected for edit")
                    }
                    Text(start).fontWeight(.semibold)
                }
                .frame(width: Self.start, alignment: .leading)
                Group {
                    if live {
                        HStack(spacing: 6) {
                            Circle().fill(.white).frame(width: 6, height: 6).modifier(Pulse())
                            Text("Now").font(WP.font(12, .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .background(WP.cobalt, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Text(end)
                    }
                }
                .frame(width: Self.end, alignment: .leading)
                Text(Fmt.duration(session.duration)).fontWeight(.semibold).frame(width: Self.duration, alignment: .trailing)
                HStack(spacing: 6) {
                    HistorySwatch(kind: session.kind)
                    Text(HistoryText.kind(session.kind))
                }
                .padding(.leading, 20).frame(width: Self.type, alignment: .leading)
                HStack(spacing: 8) {
                    if let name = session.appName { AppTile(name: name, bundleID: session.bundleID, size: 18) }
                    Text(session.appName ?? "—").foregroundStyle(session.appName == nil ? WP.caption : WP.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(WP.font(13)).monospacedDigit().foregroundStyle(WP.ink).lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: Self.height)
            .background(selected ? WP.cobalt.opacity(0.12) : hovered ? WP.hover.opacity(0.5) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(WP.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(session.appName ?? "No application")
        .accessibilityLabel("\(start) to \(live ? "now" : end), \(Fmt.duration(session.duration)), \(HistoryText.kind(session.kind)), \(session.appName ?? "No application")")
        .accessibilityHint("Opens this session for edit")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Edit panel

/// Correct, delete or add one session. `onClose` closes the panel; without it, the view dismisses itself.
struct SessionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Session
    /// Category id, or 0 for "Idle".
    @State private var classTag: Int64
    @State private var confirmingDelete = false
    private let originalTag: Int64
    private let onClose: (() -> Void)?

    init(session: Session, onClose: (() -> Void)? = nil) {
        let tag = session.kind == .idle ? 0 : (session.categoryID ?? Store.uncategorizedID)
        _draft = State(initialValue: session)
        _classTag = State(initialValue: tag)
        originalTag = session.id == 0 ? -1 : tag
        self.onClose = onClose
    }

    private var isNew: Bool { draft.id == 0 }
    private var invalid: Bool { draft.end <= draft.start || draft.end > Date().addingTimeInterval(1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(isNew ? "Add session" : "Edit session")
                Text(HistoryText.day(HistoryText.day(of: draft), long: true)).font(WP.font(12)).foregroundStyle(WP.caption)
            }
            VStack(spacing: 6) {
                if !isNew {
                    fact("Application", draft.appName ?? "—")
                    fact("Tracking source", Fmt.source(draft.source) + (draft.edited ? " · edited" : ""))
                }
                fact("Duration", draft.end > draft.start ? Fmt.duration(draft.duration) : "—")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(WP.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) { times }
                    VStack(alignment: .leading, spacing: 10) { times }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if invalid { Image(systemName: "exclamationmark.triangle.fill").accessibilityLabel("Error") }
                    Text("End must be after Start. End cannot be later than now.").fixedSize(horizontal: false, vertical: true)
                }
                .font(WP.font(12, invalid ? .semibold : .regular)).foregroundStyle(invalid ? WP.warnInk : WP.caption)
            }

            HistoryField(label: "Category") {
                Picker("Category", selection: $classTag) {
                    ForEach(model.categories) { Text($0.name).tag($0.id) }
                    Divider()
                    Text("Idle").tag(Int64(0))
                }
                .labelsHidden().controlSize(.large).frame(maxWidth: .infinity, alignment: .leading)
            }
            HistoryField(label: "Note (optional)") {
                TextField("", text: $draft.note)
                    .textFieldStyle(.plain).font(WP.font(13)).foregroundStyle(WP.ink)
                    .wpField()
                    .onSubmit(save)
                    .accessibilityLabel("Note (optional)")
            }
            Note(text: "Your correction has priority. If it overlaps a different session, WorkPulse trims that session. Time is never counted twice.")

            HStack(spacing: 8) {
                if !isNew {
                    Button { confirmingDelete = true } label: { Label("Delete…", systemImage: "trash") }
                        .buttonStyle(WPButtonStyle(text: WP.red))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WP.red).allowsHitTesting(false))
                }
                Spacer(minLength: 0)
                Button("Cancel", action: close).buttonStyle(WPButtonStyle())
                Button("Save", action: save).buttonStyle(WPButtonStyle(kind: .primary)).disabled(invalid)
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(WP.hairline).frame(height: 1) }
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: .infinity, alignment: .leading)
        .wpCard(strong: true)
        .onExitCommand(perform: close)   // Esc, while the panel has the keyboard focus
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isNew ? "Add session" : "Edit session")
        .confirmationDialog("Delete the session from \(HistoryText.day(HistoryText.day(of: draft))) at \(HistoryText.clock(draft.start, draft))?",
                            isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                model.deleteSessions([draft.id])
                close()
            }
        } message: {
            Text("WorkPulse updates your totals, goals and reports immediately. You cannot undo this.")
        }
    }

    @ViewBuilder private var times: some View {
        timeField("Start", $draft.start)
        timeField("End", $draft.end)
    }

    /// Date and time: a session can be on a different day, or go through midnight.
    private func timeField(_ label: String, _ date: Binding<Date>) -> some View {
        HistoryField(label: label) {
            DatePicker(label, selection: date)
                .datePickerStyle(.stepperField).labelsHidden().controlSize(.large)
                .font(WP.font(13, .medium)).monospacedDigit().fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).foregroundStyle(WP.caption)
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(WP.ink).lineLimit(1)
        }
        .font(WP.font(13))
        .accessibilityElement(children: .combine)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func save() {
        guard !invalid else { return }
        var session = draft
        if classTag != originalTag {
            if classTag == 0 {
                session.kind = .idle
                session.categoryID = nil
            } else if let category = model.categories.first(where: { $0.id == classTag }) {
                session.kind = category.kind
                session.categoryID = category.id
                if category.kind == .excluded {  // ignored time keeps no application identity
                    session.bundleID = nil
                    session.appName = nil
                }
            }
        }
        if session.kind != .work { session.projectID = nil }
        if session.id == 0 {
            session.tzOffset = TimeZone.current.secondsFromGMT(for: session.start)
        } else {
            session.edited = true
            // An empty end reason means "still open". The edit closes the session.
            if session.endReason.isEmpty { session.endReason = "edit" }
        }
        if model.saveSession(session) { close() }
    }
}
