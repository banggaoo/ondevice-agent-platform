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
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.11.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
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
        /// Owned open-weight LLM runtime behind the LLMProvider seam. Kept out
        /// of PlatformCore so the deterministic core has no third-party code.
        .target(
            name: "PlatformMLX",
            dependencies: [
                "PlatformCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/PlatformMLX"
        ),
        .executableTarget(
            name: "PlatformCLI",
            dependencies: ["PlatformCore", "PlatformServing", "PlatformMLX"],
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
        .testTarget(
            name: "PlatformMLXTests",
            dependencies: ["PlatformCore", "PlatformMLX", "PlatformTestSupport"],
            path: "Tests/PlatformMLXTests"
        ),
    ]
)
