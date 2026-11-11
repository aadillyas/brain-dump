// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BrainDump",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BrainDump", targets: ["BrainDump"]),
        .executable(name: "braindump-eval", targets: ["BrainDumpEval"]),
        .library(name: "BrainDumpCore", targets: ["BrainDumpCore"]),
    ],
    dependencies: [
        // ASR only: no TTS, diarization or text-normalization engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.18.3"), traits: [])
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12284/llama-b12284-xcframework.zip",
            checksum: "3b503a596883441a7a6dcbf173a03a3332dfa5c098d2805c1dfda5157644c7e2"
        ),
        .target(
            name: "BrainDumpCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "BrainDumpLLM",
            dependencies: ["BrainDumpCore", "llama"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BrainDump",
            dependencies: [
                "BrainDumpCore",
                "BrainDumpLLM",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BrainDumpEval",
            dependencies: ["BrainDumpCore", "BrainDumpLLM"],
            path: "Sources/braindump-eval",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unit checks as a plain executable: the Command Line Tools ship no XCTest or Swift Testing.
        .executableTarget(
            name: "BrainDumpCheck",
            dependencies: ["BrainDumpCore"],
            path: "Sources/braindump-check",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
