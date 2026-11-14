import AppKit
import SwiftUI

@main
struct WorkPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            DashboardView().environment(model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.statusSymbol)
                if let text = model.menuBarText { Text(text).monospacedDigit() }
                // A dot when WorkPulse has a question ("Is this work?").
                if model.suggestion != nil { Image(systemName: "circlebadge.fill") }
            }
            .accessibilityLabel(model.menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Two trackers writing one timeline would double-count: keep a single instance.
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        AppModel.shared.start()
        // Close the open session cleanly when asked to terminate (logout, shutdown, `kill`).
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
        #if DEBUG
        // WORKPULSE_OPEN=<tab name>: open the main window at launch (for profiling with sample data).
        if let name = ProcessInfo.processInfo.environment["WORKPULSE_OPEN"],
           let tab = MainTab.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
            let env = ProcessInfo.processInfo.environment
            if env["WORKPULSE_NO_MOTION"] != nil { Motion.off = true }
            if env["WORKPULSE_NO_GLASS"] != nil { Backdrop.glass = false }
            AppModel.shared.showMain(tab)
            // WORKPULSE_CYCLE: switch through every screen three times, then quit (CPU profiling).
            if env["WORKPULSE_CYCLE"] != nil {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write(Data("cycle start\n".utf8))
                    for _ in 0..<3 {
                        for tab in MainTab.allCases {
                            withAnimation(.easeOut(duration: 0.15)) { AppModel.shared.tab = tab }
                            try? await Task.sleep(for: .seconds(1.5))
                        }
                    }
                    FileHandle.standardError.write(Data("cycle end\n".utf8))
                    NSApp.terminate(nil)
                }
            }
        }
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--snapshot"), arguments.count > i + 1 {
            Task {
                await AppModel.shared.snapshot(to: URL(fileURLWithPath: arguments[i + 1]))
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
