// swift-tools-version: 6.1
// GuavaEngine 0.0.1
import PackageDescription
import Foundation

// Engine package's absolute path — needed for linkerSettings.unsafeFlags so that
// Editor / GuavaUI can find vendored dylibs even when this package is consumed
// from a different working directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ocioOpenEXRLibDir = "\(packageDir)/vendor/ocio_openexr/macos-arm64/lib"

let package = Package(
    name: "GuavaEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "EngineKernel", targets: ["EngineKernel"]),
        .library(name: "EngineMath", targets: ["EngineMath"]),
        .library(name: "RHIWGPU", targets: ["RHIWGPU"]),
        .library(name: "PlatformShell", targets: ["PlatformShell"]),
        .library(name: "RenderBackend", targets: ["RenderBackend"]),
        .library(name: "ObservationBus", targets: ["ObservationBus"]),
        .library(name: "SceneRuntime", targets: ["SceneRuntime"]),
        .library(name: "AssetPipeline", targets: ["AssetPipeline"]),
        .library(name: "SequenceRuntime", targets: ["SequenceRuntime"]),
        .library(name: "ColorPipeline", targets: ["ColorPipeline"]),
        .library(name: "EXRIO", targets: ["EXRIO"]),
        .library(name: "CinematicRenderer", targets: ["CinematicRenderer"]),
        .library(name: "CardBattleRuntime", targets: ["CardBattleRuntime"]),
        .library(name: "IntentRuntime", targets: ["IntentRuntime"]),
        .library(name: "AIRuntime", targets: ["AIRuntime"]),
        .library(name: "ScriptRuntime", targets: ["ScriptRuntime"]),
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .executable(name: "SceneRuntimeBenchmarks", targets: ["SceneRuntimeBenchmarks"]),
        .executable(name: "RenderBackendBenchmarks", targets: ["RenderBackendBenchmarks"]),
        .executable(name: "StylizedCharacterPreviewDemo", targets: ["StylizedCharacterPreviewDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // MARK: - C Bridges
        .binaryTarget(
            name: "SDL3",
            path: "vendor/SDL3.artifactbundle"
        ),
        .target(
            name: "CSDL3",
            dependencies: ["SDL3"],
            path: "Sources/Bridge/CSDL3",
            publicHeadersPath: "include",
            linkerSettings: [
                // SDL3 static needs these macOS frameworks pulled at link time.
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS])),
                .linkedFramework("Cocoa", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.macOS])),
                .linkedFramework("CoreHaptics", .when(platforms: [.macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.macOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.macOS])),
                .linkedFramework("ForceFeedback", .when(platforms: [.macOS])),
                .linkedFramework("GameController", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("Metal", .when(platforms: [.macOS])),
                .linkedFramework("UniformTypeIdentifiers", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "CEngineBridge",
            path: "Sources/Bridge/CEngineBridge",
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "wgpu_native",
            path: "vendor/wgpu_native.artifactbundle"
        ),
        .target(
            name: "CWGPUBridge",
            dependencies: ["wgpu_native"],
            path: "Sources/Bridge/CWGPUBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                // wgpu_native (static) needs platform graphics frameworks linked at the app level.
                .linkedFramework("Metal", .when(platforms: [.macOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("IOSurface", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "CJoltBridge",
            path: "Sources/Bridge/CJoltBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "COpenEXRBridge",
            path: "Sources/Bridge/COpenEXRBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../../vendor/ocio_openexr/macos-arm64/include"),
                .headerSearchPath("../../../vendor/ocio_openexr/macos-arm64/include/OpenEXR"),
                .headerSearchPath("../../../vendor/ocio_openexr/macos-arm64/include/Imath"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ocioOpenEXRLibDir)",
                    "-lOpenEXR-3_4",
                    "-lOpenEXRUtil-3_4",
                    "-lOpenEXRCore-3_4",
                    "-lIex-3_4",
                    "-lIlmThread-3_4",
                    "-lImath-3_2",
                    // Embed absolute rpath to Engine's vendor/ so consumers (Editor, tests)
                    // resolve dylibs regardless of executable location.
                    "-Xlinker", "-rpath", "-Xlinker", ocioOpenEXRLibDir,
                ], .when(platforms: [.macOS]))
            ]
        ),

        // MARK: - Core Kernel (no deps, pure Swift protocols and types)
        .target(name: "EngineKernel"),
        .target(name: "EngineMath"),

        // MARK: - Rendering
        .target(
            name: "RHIWGPU",
            dependencies: [
                "CWGPUBridge",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - Platform
        .target(
            name: "PlatformShell",
            dependencies: [
                "CSDL3",
                "EngineKernel",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - Engine Services
        .target(name: "ObservationBus"),
        .target(
            name: "SceneRuntime",
            dependencies: [
                "EngineKernel",
                "CJoltBridge",
            ]
        ),
        .target(name: "AssetPipeline"),
        .target(name: "SequenceRuntime"),
        .target(
            name: "ColorPipeline"
        ),
        .target(
            name: "EXRIO",
            dependencies: [
                "COpenEXRBridge",
            ]
        ),
        .target(
            name: "CinematicRenderer",
            dependencies: [
                "SceneRuntime",
            ]
        ),
        .target(name: "CardBattleRuntime"),
        .target(
            name: "AIRuntime",
            dependencies: [
                "SceneRuntime",
                "IntentRuntime",
            ]
        ),
        .target(
            name: "IntentRuntime",
            dependencies: [
                "AssetPipeline",
                "ObservationBus",
                "SceneRuntime",
                "SequenceRuntime",
                "ScriptRuntime",
            ]
        ),
        .target(
            name: "ScriptRuntime",
            dependencies: [
                "SceneRuntime",
            ]
        ),
        .target(
            name: "RenderBackend",
            dependencies: [
                "EngineMath",
                "RHIWGPU",
                "AssetPipeline",
                "SceneRuntime",
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [
                .copy("Resources/FinalBaseMesh.obj"),
                .copy("Resources/Shaders"),
            ]
        ),

        // MARK: - Engine Host (orchestrates all services)
        .target(
            name: "EngineCore",
            dependencies: [
                "CEngineBridge",
                "EngineKernel",
                "RHIWGPU",
                "RenderBackend",
                "SceneRuntime",
                "AssetPipeline",
                "ScriptRuntime",
            ]
        ),
        .executableTarget(
            name: "SceneRuntimeBenchmarks",
            dependencies: [
                "SceneRuntime",
            ],
            path: "Benchmarks/SceneRuntimeBenchmarks"
        ),
        .executableTarget(
            name: "RenderBackendBenchmarks",
            dependencies: [
                "RenderBackend",
                "RHIWGPU",
                "SceneRuntime",
            ],
            path: "Benchmarks/RenderBackendBenchmarks"
        ),
        .executableTarget(
            name: "StylizedCharacterPreviewDemo",
            dependencies: [
                "RenderBackend",
                "RHIWGPU",
                "SceneRuntime",
            ],
            path: "Demos/StylizedCharacterPreviewDemo"
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: [
                "EngineCore",
                "EngineKernel",
                "EngineMath",
                "RenderBackend",
                "SceneRuntime",
            ]
        ),
        .testTarget(
            name: "EngineMathTests",
            dependencies: [
                "EngineMath",
            ]
        ),
        .testTarget(
            name: "ObservationBusTests",
            dependencies: [
                "ObservationBus",
            ]
        ),
        .testTarget(
            name: "SceneRuntimeTests",
            dependencies: [
                "EngineKernel",
                "SceneRuntime",
            ]
        ),
        .testTarget(
            name: "ScriptRuntimeTests",
            dependencies: [
                "ScriptRuntime",
                "SceneRuntime",
            ]
        ),
        .testTarget(
            name: "AssetPipelineTests",
            dependencies: [
                "AssetPipeline",
            ]
        ),
        .testTarget(
            name: "SequenceRuntimeTests",
            dependencies: [
                "SequenceRuntime",
            ]
        ),
        .testTarget(
            name: "CardBattleRuntimeTests",
            dependencies: [
                "CardBattleRuntime",
            ]
        ),
        .testTarget(
            name: "IntentRuntimeTests",
            dependencies: [
                "IntentRuntime",
                "AssetPipeline",
                "ObservationBus",
                "SceneRuntime",
                "ScriptRuntime",
                "SequenceRuntime",
            ]
        ),
        .testTarget(
            name: "ColorPipelineTests",
            dependencies: [
                "ColorPipeline",
            ]
        ),
        .testTarget(
            name: "EXRIOTests",
            dependencies: [
                "EXRIO",
            ]
        ),
        .testTarget(
            name: "CinematicRendererTests",
            dependencies: [
                "CinematicRenderer",
            ]
        ),
    ]
)
