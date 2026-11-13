import AppKit
import SwiftUI
import WorkPulseCore

/// "Setup steps…": connects Claude Code or Codex to WorkPulse. Automatic lets WorkPulse add its
/// hook entries (with a backup and Undo); Manual gives the path and the text to add by hand.
/// Every state comes from the model, so the sheet shows the first signal when it arrives.
struct AgentSetupSheet: View {
    let tool: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var manual = false
    /// The copy button that was used last ("path" or "block"; with "!" when the copy failed).
    @State private var copied: String?
    @State private var failure: String?

    private var agent: AgentInfo? { model.agents.first { $0.tool == tool } }
    private var name: String { AgentSignals.name(tool) }
    private var path: String { model.agentConfigPath(tool) }
    private var file: String { (path as NSString).lastPathComponent }
    private var snippet: String { AgentSetup.manualText(tool) }
    /// The hook events in the text that WorkPulse adds, so the list and the count are always true.
    private var events: [String] {
        let text = snippet
        return ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"].filter { text.contains($0) }
    }
    private var connected: Bool { agent?.connected ?? false }
    private var installed: Bool { agent?.hookInstalled ?? false }

    /// "Wed, 11 Nov at 15.42"
    static func signalTime(_ date: Date) -> String {
        "\(Fmt.date(date, offset: TimeZone.current.secondsFromGMT(for: date), "EEEdMMM")) at \(Fmt.time(date))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Note(tone: .good, text: "The hook sends no data. It only makes an empty file on this Mac. WorkPulse does not read prompts or output.")
            methods
            // The steps take their own height and scroll only when the screen is too small for them.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if manual { manualSteps } else { automaticStep }
                    step(manual ? 3 : 2, tool == "codex" ? "Approve the hooks in Codex" : "Start a new \(name) session", spacing: 2) {
                        prose(tool == "codex" ? "Codex asks you to approve new hooks one time." : "\(name) loads the hooks when a session starts.")
                    }
                    check
                }
            }
            .frame(maxHeight: max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 400))
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(WP.hairline).frame(height: 1).accessibilityHidden(true)
            footer
        }
        .padding(24)
        .frame(width: 640)
        .background(WP.field)
        .background {
            // Escape closes the sheet; Return presses the visible button.
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    // MARK: - Head and foot

    private var header: some View {
        HStack(spacing: 12) {
            AppTile(name: name, symbol: "terminal", size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("Set up \(name)").font(WP.font(20, .bold)).tracking(-0.2).foregroundStyle(WP.ink)
                    .accessibilityAddTraits(.isHeader)
                prose("\(manual ? "Three" : "Two") steps and one check. Then WorkPulse counts \(name) work as your work.")
            }
        }
    }

    private var methods: some View {
        HStack(spacing: 2) {
            method("Automatic (recommended)", on: !manual) { manual = false }
            method("Manual", on: manual) { manual = true }
        }
        .padding(2)
        .background(WP.track, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Setup method")
    }

    private func method(_ title: String, on: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 5) {
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)) }
                Text(title).font(WP.font(13, on ? .semibold : .medium))
            }
            .foregroundStyle(on ? WP.ink : WP.secondary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WP.field)
                        .shadow(color: WP.navy.opacity(0.2), radius: 1.5, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Link(destination: URL(string: "https://github.com/sayyidsenpai/workpulse/blob/main/docs/ai-agents.md")!) {
                Text("Full guide on GitHub").font(WP.font(13, .medium)).underline().foregroundStyle(WP.textBlue)
            }
            Spacer(minLength: 12)
            // 96 pt or more wide: the style adds 12 pt on each side.
            Button { dismiss() } label: { Text(connected ? "Done" : "Close").font(WP.font(14, .semibold)).frame(minWidth: 72) }
                .buttonStyle(WPButtonStyle(kind: connected ? .primary : .secondary, height: 36))
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Steps

    private var automaticStep: some View {
        step(1, "Let WorkPulse add the hooks", spacing: 10) {
            prose("WorkPulse changes one file only:")
            code(path)
            VStack(alignment: .leading, spacing: 6) {
                tick("It saves a backup of the file first.")
                tick("It adds \(events.count) hook entries for WorkPulse.")
                tick("It keeps all your other settings.")
            }
            if installed {
                HStack(spacing: 10) {
                    CheckBadge()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Hooks added to \(file)").font(WP.font(13, .semibold))
                        Text(model.agentBackupPath(tool).map { "Backup: \($0)" } ?? "No backup: the file did not exist before.")
                            .font(WP.font(12)).textSelection(.enabled)
                    }
                    .foregroundStyle(WP.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Undo", action: undo).buttonStyle(WPButtonStyle())
                        .accessibilityLabel("Undo: remove the WorkPulse hooks from \(file)")
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(WP.greenBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WP.green.opacity(0.35)))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    // 18 pt at each side: the style adds 12 pt.
                    Button(action: add) {
                        Label("Add the hooks to \(file)", systemImage: "plus").labelStyle(.titleAndIcon).padding(.horizontal, 6)
                    }
                    .buttonStyle(WPButtonStyle(kind: .primary, height: 40, radius: 10))
                    .shadow(color: WP.cobalt.opacity(0.3), radius: 5, y: 4)
                    Text("WorkPulse changes this file only when you select this button.").font(WP.font(12)).foregroundStyle(WP.caption)
                }
            }
            if let failure { Note(tone: .warn, text: failure) }
        }
    }

    @ViewBuilder private var manualSteps: some View {
        step(1, "Open the settings file of \(name)") {
            HStack(spacing: 8) {
                code(path).frame(maxWidth: .infinity, alignment: .leading)
                copyButton("path", "Copy path", path, width: 104)
                Button("Show in Finder", action: reveal).buttonStyle(WPButtonStyle())
                    .disabled(!FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path))
            }
        }
        step(2, "Add the WorkPulse hooks to the file") {
            prose("This block adds hooks for these events: \(events.joined(separator: ", ")).")
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(file).font(WP.font(12, .semibold).monospaced()).foregroundStyle(WP.onCobalt)
                    Spacer(minLength: 8)
                    copyButton("block", "Copy block", snippet, width: 116, onNavy: true)
                }
                .padding(.leading, 12).padding([.vertical, .trailing], 6)
                Rectangle().fill(WP.onCobalt.opacity(0.16)).frame(height: 1)
                ScrollView([.vertical, .horizontal]) {
                    Text(snippet).font(WP.font(12).monospaced()).lineSpacing(3).foregroundStyle(WP.onCobalt).textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 168)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Hook settings to copy")
            }
            .background(WP.navy, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Note(tone: .warn, text: "If the file has hooks already, add this block to them. Do not replace your hooks. Then save the file.")
        }
    }

    private var check: some View {
        step(manual ? 4 : 3, "Check the connection", last: true, done: connected) {
            prose("Send one prompt to \(name). WorkPulse shows the result here.")
            HStack(spacing: 10) {
                if connected {
                    CheckBadge()
                } else {
                    Circle().strokeBorder(WP.cobalt, lineWidth: 3).frame(width: 12, height: 12).modifier(Pulse())
                }
                Text(agent?.lastSignal.map { "Connected. Last signal: \(Self.signalTime($0))." } ?? "Waiting for the first signal…")
                    .font(WP.font(13, .semibold)).monospacedDigit().foregroundStyle(WP.ink)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(connected ? WP.greenBg : WP.infoBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(connected ? WP.green.opacity(0.35) : WP.cobalt.opacity(0.3)))
            .accessibilityElement(children: .combine)
        }
    }

    /// One numbered step. The line below the number joins it to the next step.
    private func step<Content: View>(_ number: Int, _ title: String, spacing: CGFloat = 8, last: Bool = false, done: Bool = false,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(title).font(WP.font(14, .bold)).foregroundStyle(WP.ink).frame(minHeight: 28)
                .accessibilityLabel("Step \(number): \(title)")
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(.bottom, last ? 0 : 18)
        .padding(.leading, 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            VStack(spacing: 4) {
                Group {
                    if done {
                        CheckBadge(size: 28)
                    } else if last {
                        Text("\(number)").foregroundStyle(WP.textBlue)
                            .frame(width: 28, height: 28).background(WP.field, in: Circle())
                            .overlay(Circle().strokeBorder(WP.cobalt, lineWidth: 2))
                    } else {
                        Text("\(number)").foregroundStyle(.white)
                            .frame(width: 28, height: 28).background(WP.cobalt, in: Circle())
                    }
                }
                .font(WP.font(13, .bold))
                if !last { RoundedRectangle(cornerRadius: 1).fill(WP.track).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .padding(.bottom, last ? 0 : 4)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Parts

    private func prose(_ text: String) -> some View {
        Text(text).font(WP.font(13)).foregroundStyle(WP.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func tick(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(WP.green).frame(width: 16)
                .accessibilityHidden(true)
            Text(text).font(WP.font(13)).foregroundStyle(WP.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text).font(WP.font(12).monospaced()).foregroundStyle(WP.ink).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minHeight: 32)
            .background(WP.hover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WP.hairline))
    }

    /// `width`: the least width of the button, so "Copied" does not change its size.
    private func copyButton(_ id: String, _ title: String, _ text: String, width: CGFloat, onNavy: Bool = false) -> some View {
        let done = copied == id, failed = copied == id + "!"
        return Button {
            NSPasteboard.general.clearContents()
            let state = NSPasteboard.general.setString(text, forType: .string) ? id : id + "!"
            copied = state
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copied == state { copied = nil }
            }
        } label: {
            Label(done ? "Copied" : failed ? "Copy failed" : title,
                  systemImage: done ? "checkmark" : failed ? "exclamationmark.triangle" : "square.on.square")
                .labelStyle(.titleAndIcon)
                .frame(minWidth: width - 24)   // the style adds 12 pt on each side
        }
        .buttonStyle(WPButtonStyle(fill: onNavy ? .white : nil, text: onNavy ? WP.fixedBlue : nil))
    }

    // MARK: - Actions

    private var configURL: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

    /// Shows the configuration file in Finder, or its folder while the file does not exist.
    private func reveal() {
        if FileManager.default.fileExists(atPath: configURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([configURL])
        } else {
            NSWorkspace.shared.open(configURL.deletingLastPathComponent())
        }
    }

    private func add() {
        let before = model.banner
        failure = model.installAgentHooks(tool) ? nil : problem(since: before, "WorkPulse could not change \(file).")
    }

    private func undo() {
        let before = model.banner
        model.undoAgentHooks(tool)
        failure = installed ? problem(since: before, "WorkPulse could not remove the hooks from \(file).") : nil
    }

    /// The model reports errors in the banner of the main window, which the sheet covers.
    private func problem(since before: String?, _ fallback: String) -> String {
        model.banner != before ? model.banner ?? fallback : fallback
    }
}

/// A white check mark on a green circle: "connected" and "done". Text always comes with it.
struct CheckBadge: View {
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(WP.green, in: Circle())
            .accessibilityHidden(true)
    }
}
