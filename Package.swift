// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "flow-bar",
    platforms: [
        .macOS(.v13) // MenuBarExtra requires macOS 13+
    ],
    targets: [
        // Pure data/logic layer — no UI. Testable, importable by the app
        // target (added in Phase 2) and the smoke executable below.
        .target(
            name: "FlowBarCore"
        ),
        // Phase 1 verification: prints decoded in-progress tasks so the
        // flow -> JSON -> Codable path is proven before any UI exists.
        // Run with: swift run flowbar-smoke
        .executableTarget(
            name: "flowbar-smoke",
            dependencies: ["FlowBarCore"]
        ),
        // The menubar app. Build a runnable .app bundle with ./build-app.sh.
        .executableTarget(
            name: "flow-bar",
            dependencies: ["FlowBarCore"]
        ),
        // Unit tests for the pure data/logic layer. A plain executable harness
        // (not XCTest) so it runs with Command Line Tools — no Xcode needed.
        // Run with: swift run flowbar-tests
        .executableTarget(
            name: "flowbar-tests",
            dependencies: ["FlowBarCore"]
        ),
    ]
)
