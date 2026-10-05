// swift-tools-version: 6.2
// VoiceDock for Mac のパッケージ定義（PLAN §3.2〜§3.4）。依存は GRDB と Yams の 2 つだけ（exact で固定）。
import PackageDescription

/// 自分のターゲットだけに掛ける設定。依存（GRDB・Yams）には掛からない（SE-0480）。
let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let grdb: Target.Dependency = .product(name: "GRDB", package: "GRDB.swift")
let yams: Target.Dependency = .product(name: "Yams", package: "Yams")

/// TestSupport とテストが使うライブラリ（実行ファイルを除く全モジュール）。
let libraryModules: [Target.Dependency] = [
    "VDContract", "VDCore", "VDStore", "VDProcess", "VDAudio", "VDDevice",
    "VDTranscribe", "VDLLM", "VDNotes", "VDModels", "VDPipeline",
]

let package = Package(
    name: "VoiceDock",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "VoiceDockApp", targets: ["VoiceDockApp"]),
        .executable(name: "voicedock-reaper", targets: ["voicedock-reaper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "VDContract", swiftSettings: strictSettings),
        .target(name: "VDCore", dependencies: ["VDContract"], swiftSettings: strictSettings),
        .target(name: "VDStore", dependencies: ["VDContract", "VDCore", grdb], swiftSettings: strictSettings),
        .target(name: "VDProcess", dependencies: ["VDCore"], swiftSettings: strictSettings),
        .target(name: "VDAudio", dependencies: ["VDContract", "VDCore"], swiftSettings: strictSettings),
        .target(
            name: "VDDevice",
            dependencies: ["VDContract", "VDCore", "VDProcess", "VDStore", "VDAudio"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "VDTranscribe", dependencies: ["VDContract", "VDCore", "VDProcess"], swiftSettings: strictSettings),
        .target(name: "VDLLM", dependencies: ["VDContract", "VDCore", "VDProcess"], swiftSettings: strictSettings),
        .target(name: "VDNotes", dependencies: ["VDContract", "VDCore", yams], swiftSettings: strictSettings),
        .target(name: "VDModels", dependencies: ["VDContract", "VDCore"], swiftSettings: strictSettings),
        .target(
            name: "VDPipeline",
            dependencies: [
                "VDContract", "VDCore", "VDStore", "VDProcess", "VDDevice",
                "VDAudio", "VDTranscribe", "VDLLM", "VDNotes",
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(name: "VoiceDockApp", dependencies: libraryModules, swiftSettings: strictSettings),
        .executableTarget(name: "voicedock-reaper", dependencies: ["VDContract"], swiftSettings: strictSettings),

        .target(
            name: "TestSupport", dependencies: libraryModules, path: "Tests/TestSupport", swiftSettings: strictSettings),

        .testTarget(
            name: "VDContractTests", dependencies: ["VDContract", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDCoreTests", dependencies: ["VDCore", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDStoreTests", dependencies: ["VDStore", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDProcessTests", dependencies: ["VDProcess", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDAudioTests", dependencies: ["VDAudio", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDDeviceTests", dependencies: ["VDDevice", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "VDTranscribeTests", dependencies: ["VDTranscribe", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDLLMTests", dependencies: ["VDLLM", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDNotesTests", dependencies: ["VDNotes", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "VDModelsTests", dependencies: ["VDModels", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "VDPipelineTests", dependencies: ["VDPipeline", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "VoiceDockAppTests", dependencies: ["VoiceDockApp", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(name: "NoDeleteTests", dependencies: ["VDPipeline", "TestSupport"], swiftSettings: strictSettings),
        .testTarget(
            name: "ReaperTests",
            dependencies: ["VDContract", "voicedock-reaper", "TestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "PolicyTests", dependencies: ["TestSupport", "VDContract"], swiftSettings: strictSettings),
        .testTarget(
            name: "LLMAcceptance", dependencies: ["VDPipeline", "VDLLM", "TestSupport"], swiftSettings: strictSettings),
    ],
    swiftLanguageModes: [.v6]
)
