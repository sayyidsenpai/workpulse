#if DEBUG
import AppKit
import SwiftUI

extension AppModel {
    /// Development aid, debug builds only (`WorkPulse --snapshot <folder>`): renders every screen
    /// to a PNG, in light and dark appearance, so the UI can be reviewed without screen capture.
    func snapshot(to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            await capture(DashboardView().environment(self), size: nil, appearance: appearance,
                          to: folder.appendingPathComponent("dashboard\(suffix).png"))
            if let session = try? store.sessions().last(where: { $0.kind == .work }) {
                await capture(SessionEditor(session: session).environment(self), size: nil, appearance: appearance,
                              to: folder.appendingPathComponent("editor\(suffix).png"))
            }
            for tab in MainTab.allCases {
                self.tab = tab
                await capture(MainView().environment(self), size: NSSize(width: 940, height: 800), appearance: appearance,
                              to: folder.appendingPathComponent("\(tab.rawValue.lowercased())\(suffix).png"))
            }
        }
    }

    private func capture(_ view: some View, size: NSSize?, appearance: NSAppearance.Name, to url: URL) async {
        FileHandle.standardError.write(Data("snapshot \(url.lastPathComponent)\n".utf8))
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))  // off screen
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1.5))  // let onAppear-driven loads finish
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.close()
    }
}
#endif
