// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ember",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ember", targets: ["Ember"]), .executable(name: "EmberFanHelper", targets: ["EmberFanHelper"]), .executable(name: "EmberFanClient", targets: ["EmberFanClient"])],
    targets: [
        .target(name: "TelemetryBridge", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "HeatCore"),
        .target(name: "FanIPC"),
        .executableTarget(name: "EmberFanClient", dependencies: ["FanIPC"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "EmberFanHelper", dependencies: ["FanIPC", "TelemetryBridge"]),
        .executableTarget(name: "Ember", dependencies: ["HeatCore", "TelemetryBridge", "FanIPC"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOKit")]),
        .testTarget(name: "HeatCoreTests", dependencies: ["HeatCore", "TelemetryBridge"])
    ]
)
