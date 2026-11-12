import SwiftUI
import WorkPulseCore

/// Searchable session history by day, week, month, custom range or all time, with editing.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    enum Scope: String, CaseIterable, Identifiable {
        case day = "Day", week = "Week", month = "Month", custom = "Range", all = "All"
        var id: String { rawValue }
    }

    @State private var scope = Scope.day
    @State private var anchor = Date()
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var search = ""
    @State private var kind: SessionKind?
    @State private var sessions: [Session] = []
    @State private var totals = DayTotals()
    @State private var selection = Set<Int64>()
    @State private var editing: Session?
    @State private var confirmingDelete = false

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
        VStack(spacing: 8) {
            controls
            table
            footer
        }
        .onChange(of: query, initial: true) { load() }
        .sheet(item: $editing) { SessionEditor(session: $0) }
        .confirmationDialog("Delete \(selection.count) session\(selection.count == 1 ? "" : "s")?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                model.deleteSessions(selection)
                selection = []
            }
        } message: {
            Text("Totals, goals and reports update immediately. This cannot be undone.")
        }
    }

    private func load() {
        do {
            let kinds = kind.map { Set([$0]) }
            let found = try range.map { try model.store.sessions(days: $0, search: search, kinds: kinds) }
                ?? model.store.sessions(search: search, kinds: kinds)
            sessions = found.reversed()
            totals = Aggregator.sum(Aggregator.dayTotals(found), in: range)
            selection.formIntersection(Set(found.map(\.id)))
        } catch {
            model.banner = error.localizedDescription
        }
    }

    private func shift(_ direction: Int) {
        let unit: Calendar.Component = scope == .day ? .day : scope == .week ? .weekOfYear : .month
        anchor = Calendar.current.date(byAdding: unit, value: direction, to: anchor) ?? anchor
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Range", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            if scope == .custom {
                DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden()
                Text("to")
                DatePicker("To", selection: $to, displayedComponents: .date).labelsHidden()
            } else if scope != .all {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("Previous")
                DatePicker("Date", selection: $anchor, displayedComponents: .date).labelsHidden()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("Next")
                Button("Today") { anchor = Date() }
            }

            Picker("Type", selection: $kind) {
                Text("All types").tag(SessionKind?.none)
                ForEach(SessionKind.allCases, id: \.self) { Text(Fmt.kind($0)).tag(SessionKind?.some($0)) }
            }
            .labelsHidden().fixedSize()

            TextField("Search app, note, project, category", text: $search)
                .textFieldStyle(.roundedBorder).frame(minWidth: 140)
        }
    }

    private var table: some View {
        Table(sessions, selection: $selection) {
            TableColumn("Start") { s in Text(Fmt.date(s.start, offset: s.tzOffset, "EEEdMMMHHmm")) }.width(min: 120, ideal: 140)
            TableColumn("End") { s in Text(Fmt.date(s.end, offset: s.tzOffset, "HHmm")) }.width(50)
            TableColumn("Duration") { s in Text(Fmt.duration(s.duration)).monospacedDigit() }.width(70)
            TableColumn("Type") { s in Text(Fmt.kind(s.kind)).foregroundStyle(s.kind == .work ? .primary : .secondary) }.width(70)
            TableColumn("Application") { s in Text(s.appName ?? (s.source == .entry ? "Manual entry" : "—")) }
            TableColumn("Category") { s in Text(model.categoryName(s)) }
            TableColumn("Project") { s in Text(s.projectID == nil ? "—" : model.projectName(s.projectID)) }
            TableColumn("Source") { s in Text(sourceLabel(s)) }.width(110)
            TableColumn("Note") { s in Text(s.note).lineLimit(1) }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button("Edit…") { edit(ids) }.disabled(ids.count != 1)
            Button("Delete", role: .destructive) {
                selection = ids
                confirmingDelete = true
            }
        } primaryAction: { ids in
            edit(ids)
        }
    }

    private func sourceLabel(_ s: Session) -> String {
        s.edited ? Fmt.source(s.source) + " · edited" : Fmt.source(s.source)
    }

    private func edit(_ ids: Set<Int64>) {
        editing = sessions.first { ids.contains($0.id) }
    }

    private func newSession() {
        let now = Date()
        editing = Session(start: now.addingTimeInterval(-3600), end: now, tzOffset: TimeZone.current.secondsFromGMT(for: now),
                          kind: .work, categoryID: Store.workID, projectID: model.settings.activeProjectID,
                          source: .entry, endReason: "manual")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(sessions.count) sessions · work \(Fmt.duration(totals.work)) · active apps \(Fmt.duration(totals.active)) · idle \(Fmt.duration(totals.idle)) · excluded \(Fmt.duration(totals.excluded))")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Add Session…", action: newSession).help("Create a session that was not tracked")
            Button("Edit…") { edit(selection) }.disabled(selection.count != 1)
            Button("Delete…") { confirmingDelete = true }.disabled(selection.isEmpty)
            Button("Export CSV…") {
                let categories = Dictionary(uniqueKeysWithValues: model.categories.map { ($0.id, $0.name) })
                let projects = Dictionary(uniqueKeysWithValues: model.projects.map { ($0.id, $0.name) })
                model.export(CSV.sessions(sessions.reversed(), categories: categories, projects: projects), name: "workpulse-sessions.csv")
            }
            .disabled(sessions.isEmpty)
        }
    }
}

/// Inspect, correct or create one session.
struct SessionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Session
    /// Category id, or 0 for "Idle".
    @State private var classTag: Int64
    private let originalTag: Int64
    @State private var error: String?

    init(session: Session) {
        let tag = session.kind == .idle ? 0 : (session.categoryID ?? Store.uncategorizedID)
        _draft = State(initialValue: session)
        _classTag = State(initialValue: tag)
        originalTag = session.id == 0 ? -1 : tag
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if draft.id != 0 {
                    Section {
                        LabeledContent("Application", value: draft.appName ?? "—")
                        LabeledContent("Tracking source", value: Fmt.source(draft.source))
                        if !draft.endReason.isEmpty { LabeledContent("Ended by", value: draft.endReason) }
                    }
                }
                Section {
                    DatePicker("Start", selection: $draft.start)
                    DatePicker("End", selection: $draft.end)
                    LabeledContent("Duration", value: draft.end > draft.start ? Fmt.duration(draft.duration) : "—")
                }
                Section {
                    Picker("Category", selection: $classTag) {
                        ForEach(model.categories) { Text($0.name).tag($0.id) }
                        Divider()
                        Text("Idle").tag(Int64(0))
                    }
                    Picker("Project", selection: $draft.projectID) {
                        Text("No project").tag(Int64?.none)
                        ForEach(model.projects) { Text($0.name).tag(Int64?.some($0.id)) }
                    }
                    TextField("Note", text: $draft.note, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    Text("Manual corrections take priority: any part of another session that overlaps this one is trimmed or replaced, so time is never counted twice.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)

            HStack {
                if draft.id != 0 {
                    Button("Delete", role: .destructive) {
                        model.deleteSessions([draft.id])
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: draft.id != 0 ? 520 : 420)
    }

    private func save() {
        guard draft.end > draft.start else { return error = "The end time must be after the start time." }
        guard draft.end <= Date().addingTimeInterval(1) else { return error = "A session cannot end in the future." }
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
        }
        if model.saveSession(session) { dismiss() }
    }
}
