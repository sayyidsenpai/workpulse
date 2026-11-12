import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WorkPulseCore

/// Application rules (category, idle behaviour, project), plus the categories and projects themselves.
struct RulesView: View {
    @Environment(AppModel.self) private var model

    private struct AppRow: Identifiable {
        let id: String  // bundle identifier
        let name: String
    }

    @State private var apps: [AppRow] = []
    @State private var newCategory = ""
    @State private var newCategoryKind = SessionKind.work
    @State private var newProject = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each application has a category, and the category decides whether its time counts as work. Applications in “Ignored” are excluded: only the duration is kept, never which app it was. Changes apply from now on and never rewrite recorded history.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Count applications without a rule as work", isOn: model.binding(\.unclassifiedIsWork))
            Label("Browsers are never counted as work automatically. WorkPulse does not read tabs, sites or URLs, so a browser's category applies to all browsing. Give the browser a category yourself, or leave it uncategorized and use a manual session (Hybrid mode) for browser-based work.", systemImage: "globe")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            table

            HStack {
                Button("Add Application…", action: addApplication)
                Spacer()
                Text("Idle override: how long without input before this app's time stops counting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                GroupBox { categories.padding(6) }
                GroupBox { projects.padding(6) }
            }
        }
        .onChange(of: model.revision, initial: true) { loadApps() }
    }

    private func loadApps() {
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier { names[id] = app.localizedName ?? id }
        }
        for app in (try? model.store.knownApps()) ?? [] where names[app.bundleID] == nil { names[app.bundleID] = app.name }
        for rule in model.rules where names[rule.bundleID] == nil { names[rule.bundleID] = rule.appName }
        apps = names.map { AppRow(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func bind<T>(_ row: AppRow, _ keyPath: WritableKeyPath<AppRule, T>) -> Binding<T> {
        Binding(get: { (model.rule(for: row.id) ?? AppRule(bundleID: row.id, appName: row.name))[keyPath: keyPath] },
                set: { value in
                    var rule = model.rule(for: row.id) ?? AppRule(bundleID: row.id, appName: row.name)
                    rule[keyPath: keyPath] = value
                    model.setRule(rule)
                })
    }

    private var table: some View {
        Table(apps) {
            TableColumn("Application") { row in
                HStack(spacing: 6) {
                    Text(row.name)
                    if Browsers.isBrowser(row.id) {
                        Text("Browser").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            TableColumn("Category") { row in
                Picker("Category", selection: bind(row, \.categoryID)) {
                    ForEach(model.categories) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            .width(min: 130, ideal: 150)
            TableColumn("Idle override") { row in
                Picker("Idle override", selection: bind(row, \.idleThreshold)) {
                    Text("Default").tag(Int?.none)
                    ForEach([60, 300, 600, 1800, 3600], id: \.self) { Text("\($0 / 60) min").tag(Int?.some($0)) }
                    Text("Never idle").tag(Int?.some(0))
                }
                .labelsHidden()
            }
            .width(min: 110, ideal: 120)
            TableColumn("Project") { row in
                Picker("Project", selection: bind(row, \.projectID)) {
                    Text("Active project").tag(Int64?.none)
                    ForEach(model.projects) { Text($0.name).tag(Int64?.some($0.id)) }
                }
                .labelsHidden()
            }
            .width(min: 130, ideal: 150)
        }
        .frame(minHeight: 180)
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an application to create a rule for"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        model.setRule(AppRule(bundleID: id, appName: name, categoryID: Store.workID))
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Categories").font(.headline)
            ForEach(model.categories) { category in
                HStack {
                    Text(category.name)
                    Spacer()
                    if category.builtin {
                        Text(Fmt.kind(category.kind)).foregroundStyle(.secondary)
                    } else {
                        Picker("Counts as", selection: Binding(get: { category.kind }, set: { kind in
                            var changed = category
                            changed.kind = kind
                            model.edit { try model.store.saveCategory(changed) }
                        })) {
                            Text("Work").tag(SessionKind.work)
                            Text("Non-work").tag(SessionKind.nonwork)
                        }
                        .labelsHidden().fixedSize()
                        Button { model.edit { try model.store.deleteCategory(category.id) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete category; its apps become Uncategorized")
                    }
                }
            }
            HStack {
                TextField("New category", text: $newCategory).textFieldStyle(.roundedBorder)
                Picker("Counts as", selection: $newCategoryKind) {
                    Text("Work").tag(SessionKind.work)
                    Text("Non-work").tag(SessionKind.nonwork)
                }
                .labelsHidden().fixedSize()
                Button("Add") {
                    let name = newCategory.trimmingCharacters(in: .whitespaces)
                    model.edit { try model.store.saveCategory(WorkCategory(name: name, kind: newCategoryKind)) }
                    newCategory = ""
                }
                .disabled(newCategory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Projects / work profiles").font(.headline)
            if model.projects.isEmpty {
                Text("Optional. A project groups work time and can have its own goals.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.projects) { project in
                HStack {
                    Text(project.name)
                    Spacer()
                    Button { model.deleteProject(project.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete project; its sessions are kept without a project")
                }
            }
            HStack {
                TextField("New project", text: $newProject).textFieldStyle(.roundedBorder)
                Button("Add") {
                    let name = newProject.trimmingCharacters(in: .whitespaces)
                    model.edit { try model.store.saveProject(Project(name: name)) }
                    newProject = ""
                }
                .disabled(newProject.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
