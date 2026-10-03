// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ondevice-agent-platform",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PlatformCore", targets: ["PlatformCore"]),
        .library(name: "PlatformServing", targets: ["PlatformServing"]),
        .executable(name: "ondevice-agent-platform", targets: ["PlatformCLI"]),
        .executable(name: "acp-fixture", targets: ["ACPFixture"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "PlatformCore", dependencies: ["CSQLite"], path: "Sources/PlatformCore"),
        .target(
            name: "PlatformServing",
            dependencies: ["PlatformCore"],
            path: "Sources/PlatformServing",
            resources: [.process("Console")]
        ),
        .executableTarget(
            name: "PlatformCLI",
            dependencies: ["PlatformCore", "PlatformServing"],
            path: "Sources/PlatformCLI"
        ),
        .target(
            name: "PlatformTestSupport",
            dependencies: ["PlatformCore", "CSQLite"],
            path: "Tests/Support/PlatformTestSupport"
        ),
        // Test-only stdio fixture used by PlatformServingTests; never part of
        // the product daemon.
        .executableTarget(
            name: "ACPFixture",
            dependencies: ["PlatformCore", "PlatformServing"],
            path: "Tests/Support/ACPFixture"
        ),
        .testTarget(
            name: "PlatformCoreTests",
            dependencies: ["PlatformCore", "PlatformTestSupport", "CSQLite"],
            path: "Tests/PlatformCoreTests"
        ),
        .testTarget(
            name: "PlatformServingTests",
            dependencies: ["PlatformCore", "PlatformServing", "PlatformTestSupport"],
            path: "Tests/PlatformServingTests"
        ),
    ]
)
