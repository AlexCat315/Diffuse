// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Resolve the absolute path to the Engine package directory so that linker
// search paths work correctly whether this package is built standalone or as
// a dependency of Editor / other packages.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let wgpuLibDir = "\(packageDir)/vendor/wgpu/lib"

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
        .systemLibrary(
            name: "CSDL3",
            path: "Sources/Bridge/CSDL3",
            pkgConfig: "sdl3",
            providers: [
                .brew(["sdl3", "pkg-config"])
            ]
        ),
        .target(
            name: "CEngineBridge",
            path: "Sources/Bridge/CEngineBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CWGPUBridge",
            path: "Sources/Bridge/CWGPUBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../../vendor/wgpu/include")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", wgpuLibDir,
                    "-lwgpu_native",
                    "-Xlinker", "-rpath", "-Xlinker", wgpuLibDir,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../vendor/wgpu/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../vendor/wgpu/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/wgpu/lib",
                ])
            ]
        ),
        .target(
            name: "CJoltBridge",
            path: "Sources/Bridge/CJoltBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "COCIOBridge",
            path: "Sources/Bridge/COCIOBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-lOpenColorIO",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib",
                ])
            ]
        ),
        .target(
            name: "COpenEXRBridge",
            path: "Sources/Bridge/COpenEXRBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I/opt/homebrew/include",
                    "-I/opt/homebrew/include/OpenEXR",
                    "-I/opt/homebrew/include/Imath",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/lib",
                    "-lOpenEXR-3_4",
                    "-lOpenEXRUtil-3_4",
                    "-lOpenEXRCore-3_4",
                    "-lIex-3_4",
                    "-lIlmThread-3_4",
                    "-L/opt/homebrew/Cellar/imath/3.2.2/lib",
                    "-lImath-3_2",
                    "-Xlinker", "-rpath", "-Xlinker", "/opt/homebrew/lib",
                ])
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
            name: "ColorPipeline",
            dependencies: [
                "COCIOBridge",
            ]
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
