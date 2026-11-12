// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WorkPulse",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: models, SQLite storage, tracking engine, analytics. No UI, fully unit-tested.
        .target(name: "WorkPulseCore"),
        // Menu bar app: SwiftUI + AppKit glue around the core.
        .executableTarget(name: "WorkPulse", dependencies: ["WorkPulseCore"]),
        .testTarget(name: "WorkPulseCoreTests", dependencies: ["WorkPulseCore"]),
    ]
)
