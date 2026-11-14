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

    /// The least width of a menu in the table: "Uncategorized" fits.
    private static let menuWidth: CGFloat = 136
    /// The width of the "Counts as" menus and of the label of the button at the end of a category row.
    private static let kindWidth: CGFloat = 116
    private static let actionWidth: CGFloat = 28
    /// Idle times a user can choose, in seconds.
    private static let idleChoices = [300, 600, 900, 1800]

    var body: some View {
        Screen(maxWidth: 1046) {   // the width of the content area on the artboard
            ScreenHeader(title: "Apps", subtitle: "Each application has a category. In the Work profile, the category sets if its time counts as work. Changes apply from now on. Recorded history does not change.") {
                Button(action: addApplication) { Label("Add Application…", systemImage: "plus") }
                    .buttonStyle(WPButtonStyle(kind: .primary))
                    .shadow(color: WP.cobalt.opacity(0.3), radius: 5, y: 4)
            }
            Note(text: "Browsers do not count as work automatically. WorkPulse does not read tabs, sites, or URLs. Give the browser a category. Its time counts only in the Work profile.")
            // Side by side when there is room, one below the other in a narrow window.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    applications.frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity)
                    categories.frame(width: 320)
                }
                VStack(spacing: 16) { applications; categories }
            }
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

    /// Label, switch, then the word On or Off (the order on the artboard).
    private var unclassifiedSwitch: some View {
        let isOn = model.binding(\.unclassifiedIsWork)
        return HStack(spacing: 10) {
            Text("Count applications without a rule as work").font(WP.font(13, .medium)).foregroundStyle(WP.ink)
                .fixedSize(horizontal: false, vertical: true)
            WPSwitch(isOn: isOn)
            Text(isOn.wrappedValue ? "On" : "Off").font(WP.font(13, .semibold)).foregroundStyle(WP.secondary)
                .frame(minWidth: 22, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Count applications without a rule as work")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAction { isOn.wrappedValue.toggle() }
    }

    /// One line of the table. The application column takes its width first (250 pt at most),
    /// then the two menu columns share the remaining width equally.
    private func columns(_ application: some View, _ category: some View, _ idle: some View) -> some View {
        HStack(spacing: 16) {
            application.frame(maxWidth: 250, alignment: .leading).layoutPriority(1)
            category.frame(minWidth: Self.menuWidth, maxWidth: .infinity, alignment: .leading)
            idle.frame(minWidth: Self.menuWidth, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    // ponytail: every row is built at once (two menus each); use a lazy stack if lists pass a few hundred applications.
    private var applications: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SectionTitle("Applications").frame(maxWidth: .infinity, alignment: .leading)
                    unclassifiedSwitch.fixedSize()
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Applications")
                    unclassifiedSwitch
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            if apps.isEmpty {
                Text("WorkPulse found no applications. To add one, click Add Application….")
                    .font(WP.font(13)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { line }
            } else {
                columns(Text("Application"), Text("Category"), Text("Idle override"))
                    .font(WP.font(12, .medium)).foregroundStyle(WP.caption)
                    .padding(.vertical, 8)
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
        // A long name continues on a second line: it is not cut off.
        let name = Text(row.name).font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        let badge = Text("Browser").font(WP.font(11, .semibold)).foregroundStyle(WP.secondary)
            .padding(.horizontal, 8).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(WP.border))
            .fixedSize()
        let browser = Browsers.isBrowser(row.id)
        return columns(
            HStack(spacing: 10) {
                AppTile(name: row.name, bundleID: row.id, size: 28)
                // "Browser" is after the name, or below it when the column is too narrow for one line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { name; if browser { badge } }
                    VStack(alignment: .leading, spacing: 2) { name; if browser { badge } }
                }
            },
            WPMenu("Category for \(row.name)", selection: bind(row, \.categoryID), options: model.categories.map { ($0.id, $0.name) }),
            WPMenu("Idle override for \(row.name)", selection: bind(row, \.idleThreshold),
                   options: [(Int?.none, "Default")] + idle.map { (Int?.some($0), "\($0 / 60) min") } + [(Int?.some(0), "Never idle")])
        )
        .padding(.vertical, 10)
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
            // 22 pt high: the title is on the line of the "Applications" title in the card beside it.
            SectionTitle("Categories").frame(height: 22)
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
            HStack(spacing: 8) {
                swatch(category)
                Text(category.name).font(WP.font(13, .semibold)).foregroundStyle(WP.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: category.builtin ? nil : .infinity, alignment: .leading)
            if category.builtin {
                // The kind of a built-in category is fixed, so it is text and not a menu.
                Text(meaning(category)).font(WP.font(13)).foregroundStyle(WP.secondary)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                // The menu and the button are in the columns of the menu and the button of the last row.
                kindPicker("\(category.name) counts as", Binding(get: { category.kind }, set: { kind in
                    var changed = category
                    changed.kind = kind
                    model.edit { try model.store.saveCategory(changed) }
                }))
                .frame(width: Self.kindWidth)
                Button { deleting = category } label: { Image(systemName: "trash").frame(width: Self.actionWidth) }
                    .buttonStyle(WPButtonStyle(text: WP.red))
                    .accessibilityLabel("Delete the category \(category.name)")
                    .help("Delete this category. Its applications become Uncategorized.")
            }
        }
        .frame(minHeight: 32)   // a row with text is as high as a row with a menu
        .padding(.vertical, 8)
    }

    /// An uncategorized application counts as work only when the switch above is on.
    private func countsAsWork(_ category: WorkCategory) -> Bool {
        category.kind == .work || (category.id == Store.uncategorizedID && model.settings.unclassifiedIsWork)
    }

    /// Cobalt for work, grey for non-work, an outline for Ignored. The text beside it says the same.
    private func swatch(_ category: WorkCategory) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Group {
            if category.kind == .excluded {
                shape.strokeBorder(WP.caption, lineWidth: 1.5)
            } else {
                shape.fill(countsAsWork(category) ? WP.cobalt : WP.switchOff)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }

    private func meaning(_ category: WorkCategory) -> String {
        if category.kind == .excluded { return "Excluded. WorkPulse records only the duration." }
        return countsAsWork(category) ? "Counts as work." : "Counts as non-work."
    }

    private func kindPicker(_ label: String, _ selection: Binding<SessionKind>) -> some View {
        WPMenu(label, selection: selection, options: [(SessionKind.work, "Work"), (SessionKind.nonwork, "Non-work")])
    }

    private var newName: String { newCategory.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { model.categories.contains { $0.name.caseInsensitiveCompare(newName) == .orderedSame } }

    private var newCategoryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("New category")
                    TextField("New category", text: $newCategory, prompt: Text(""))
                        .textFieldStyle(.plain).font(WP.font(13)).foregroundStyle(WP.ink)
                        .wpField()
                        .onChange(of: newCategory) { if newCategory.count > 40 { newCategory = String(newCategory.prefix(40)) } }
                        .onSubmit(addCategory)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel("Counts as")
                    kindPicker("New category counts as", $newCategoryKind).frame(width: Self.kindWidth)
                }
                Button(action: addCategory) { Text("Add").frame(width: Self.actionWidth) }
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
