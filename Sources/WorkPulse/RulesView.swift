import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkPulseCore

/// The "Apps" screen: the category and the idle time of each application, and the categories.
struct RulesView: View {
    @Environment(AppModel.self) private var model

    private struct AppRow: Identifiable, Equatable {
        let id: String  // bundle identifier
        let name: String
    }

    @State private var apps: [AppRow] = []
    @State private var newCategory = ""
    @State private var newCategoryKind = SessionKind.work
    @State private var deleting: WorkCategory?

    private static let categoryWidth: CGFloat = 136
    private static let idleWidth: CGFloat = 118
    /// Idle times a user can choose, in seconds.
    private static let idleChoices = [300, 600, 900, 1800]

    var body: some View {
        Screen {
            ScreenHeader(title: "Apps", subtitle: "Each application has a category. In the Work profile, the category sets if its time counts as work. Changes apply from now on. Recorded history does not change.") {
                Button(action: addApplication) { Label("Add Application…", systemImage: "plus") }
                    .buttonStyle(WPButtonStyle(kind: .primary))
            }
            Note(text: "Browsers do not count as work automatically. WorkPulse does not read tabs, sites, or URLs. Give the browser a category. Its time counts only in the Work profile.")
                .wpRise(1)
            // Side by side when there is room, one below the other in a narrow window.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    applications.frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity)
                    categories.frame(width: 320)
                }
                VStack(spacing: 16) { applications; categories }
            }
            .wpRise(2)
        }
        .onChange(of: model.revision, initial: true) { loadApps() }
        .confirmationDialog("Delete the category “\(deleting?.name ?? "")”?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { category in
            Button("Delete Category", role: .destructive) { model.edit { try model.store.deleteCategory(category.id) } }
        } message: { _ in
            Text("Its applications become Uncategorized.")
        }
    }

    private var line: some View { Rectangle().fill(WP.hairline).frame(height: 1) }

    // MARK: Applications

    private func loadApps() {
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier { names[id] = app.localizedName ?? id }
        }
        for app in (try? model.store.knownApps()) ?? [] where names[app.bundleID] == nil { names[app.bundleID] = app.name }
        for rule in model.rules where names[rule.bundleID] == nil { names[rule.bundleID] = rule.appName }
        let rows = names.map { AppRow(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if rows != apps { apps = rows }
    }

    private func bind<T>(_ row: AppRow, _ keyPath: WritableKeyPath<AppRule, T>) -> Binding<T> {
        Binding(get: { (model.rule(for: row.id) ?? AppRule(bundleID: row.id, appName: row.name))[keyPath: keyPath] },
                set: { value in
                    var rule = model.rule(for: row.id) ?? AppRule(bundleID: row.id, appName: row.name)
                    rule[keyPath: keyPath] = value
                    rule.projectID = nil   // projects are gone from the interface
                    model.setRule(rule)
                })
    }

    private var unclassifiedSwitch: some View {
        Toggle("Count applications without a rule as work", isOn: model.binding(\.unclassifiedIsWork))
            .toggleStyle(WPSwitchStyle())
    }

    // ponytail: every row is built at once (two menus each); use a lazy stack if lists pass a few hundred applications.
    private var applications: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SectionTitle("Applications")
                    Spacer(minLength: 12)
                    unclassifiedSwitch.fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Applications")
                    unclassifiedSwitch
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            if apps.isEmpty {
                Text("WorkPulse found no applications. To add one, click Add Application….")
                    .font(WP.font(13)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { line }
            } else {
                HStack(spacing: 8) {
                    Text("Application").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Category").frame(width: Self.categoryWidth, alignment: .leading)
                    Text("Idle override").frame(width: Self.idleWidth, alignment: .leading)
                }
                .font(WP.font(12, .medium)).foregroundStyle(WP.caption)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .overlay(alignment: .top) { line }
                ForEach(apps) { appRow($0) }
            }
            Text("Idle override: the time without input before the time of this application stops counting.")
                .font(WP.font(12)).foregroundStyle(WP.caption).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { line }
        }
        .wpCard(padding: 0, strong: true)
    }

    private func appRow(_ row: AppRow) -> some View {
        // An idle time that an earlier version stored stays in the menu.
        let stored = model.rule(for: row.id)?.idleThreshold ?? 0
        let idle = (Self.idleChoices + (stored > 0 && !Self.idleChoices.contains(stored) ? [stored] : [])).sorted()
        return HStack(spacing: 8) {
            HStack(spacing: 10) {
                AppTile(name: row.name, bundleID: row.id, size: 28)
                Text(row.name).font(WP.font(13, .semibold)).foregroundStyle(WP.ink).lineLimit(1)
                if Browsers.isBrowser(row.id) {
                    Text("Browser").font(WP.font(11, .semibold)).foregroundStyle(WP.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WP.border))
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Category for \(row.name)", selection: bind(row, \.categoryID)) {
                ForEach(model.categories) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().frame(width: Self.categoryWidth)
            Picker("Idle override for \(row.name)", selection: bind(row, \.idleThreshold)) {
                Text("Default").tag(Int?.none)
                ForEach(idle, id: \.self) { Text("\($0 / 60) min").tag(Int?.some($0)) }
                Text("Never idle").tag(Int?.some(0))
            }
            .labelsHidden().frame(width: Self.idleWidth)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .overlay(alignment: .top) { line }
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an application to add."
        // An application that has a rule keeps it.
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              model.rule(for: id) == nil else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        // A browser is never set to Work automatically: the user chooses its category.
        model.setRule(AppRule(bundleID: id, appName: name, categoryID: Browsers.isBrowser(id) ? Store.nonworkID : Store.workID))
    }

    // MARK: Categories

    private var categories: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Categories")
            VStack(spacing: 0) {
                ForEach(model.categories) { category in
                    categoryRow(category)
                        .overlay(alignment: .top) { if category.id != model.categories.first?.id { line } }
                }
            }
            newCategoryRow
                .padding(.top, 12)
                .overlay(alignment: .top) { line }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wpCard(strong: true)
    }

    private func categoryRow(_ category: WorkCategory) -> some View {
        HStack(spacing: 8) {
            swatch(category)
            Text(category.name).font(WP.font(13, .semibold)).foregroundStyle(WP.ink).lineLimit(1)
                .layoutPriority(category.builtin ? 1 : 0)
            Spacer(minLength: 4)
            if category.builtin {
                // The kind of a built-in category is fixed, so it is text and not a menu.
                Text(meaning(category)).font(WP.font(13)).foregroundStyle(WP.secondary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            } else {
                kindPicker("\(category.name) counts as", Binding(get: { category.kind }, set: { kind in
                    var changed = category
                    changed.kind = kind
                    model.edit { try model.store.saveCategory(changed) }
                }))
                .frame(width: 116)
                Button { deleting = category } label: {
                    Image(systemName: "trash").font(WP.font(13, .medium)).foregroundStyle(WP.red)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete the category \(category.name)")
                .help("Delete this category. Its applications become Uncategorized.")
            }
        }
        .padding(.vertical, 8)
    }

    /// Cobalt for work, grey for non-work, an outline for Ignored. The text beside it says the same.
    private func swatch(_ category: WorkCategory) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let work = category.kind == .work || (category.id == Store.uncategorizedID && model.settings.unclassifiedIsWork)
        return Group {
            if category.kind == .excluded {
                shape.strokeBorder(WP.caption, lineWidth: 1.5)
            } else {
                shape.fill(work ? WP.cobalt : WP.switchOff)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }

    private func meaning(_ category: WorkCategory) -> String {
        switch category.id {
        case Store.ignoredID: "Excluded. WorkPulse records only the duration."
        case Store.uncategorizedID: "Applications without a rule."
        default: category.kind == .work ? "Counts as work." : "Counts as non-work."
        }
    }

    private func kindPicker(_ label: String, _ selection: Binding<SessionKind>) -> some View {
        Picker(label, selection: selection) {
            Text("Work").tag(SessionKind.work)
            Text("Non-work").tag(SessionKind.nonwork)
        }
        .labelsHidden()
    }

    private var newName: String { newCategory.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { model.categories.contains { $0.name.caseInsensitiveCompare(newName) == .orderedSame } }

    private var newCategoryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("New category")
                    TextField("New category", text: $newCategory, prompt: Text("Name"))
                        .textFieldStyle(.plain).font(WP.font(13)).foregroundStyle(WP.ink)
                        .wpField()
                        .onChange(of: newCategory) { if newCategory.count > 40 { newCategory = String(newCategory.prefix(40)) } }
                        .onSubmit(addCategory)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Counts as")
                    kindPicker("New category counts as", $newCategoryKind).frame(width: 116, height: 32)
                }
                Button("Add", action: addCategory)
                    .buttonStyle(WPButtonStyle())
                    .disabled(newName.isEmpty || nameTaken)
            }
            if nameTaken {
                Text("A category with this name exists. Use a different name.")
                    .font(WP.font(12)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addCategory() {
        guard !newName.isEmpty, !nameTaken else { return }
        let category = WorkCategory(name: newName, kind: newCategoryKind)
        model.edit { try model.store.saveCategory(category) }
        newCategory = ""
    }
}
