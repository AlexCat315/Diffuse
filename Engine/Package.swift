// swift-tools-version: 6.4
// GuavaStudioRuntime 0.0.9
import PackageDescription
import Foundation

let sdkRoot = ProcessInfo.processInfo.environment["GUAVA_SDK_ROOT"]
    .map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "../GuavaUI"

// Cross builds stage target archives separately from the host's vendor directory.
let nativeArtifactRoot = ProcessInfo.processInfo.environment["GUAVA_ENGINE_ARTIFACT_ROOT"] ?? "vendor"

// GNU ld resolves static archives in one pass, while SwiftPM's native build
// system emits artifact-bundle libraries in no dependency order. CI enables
// this only for native builds; Swift Build already passes the artifacts as
// ordered absolute paths and would reject the bare -l flags.
let nativeLinkOrderSettings: [LinkerSetting] =
    ProcessInfo.processInfo.environment["GUAVA_NATIVE_LINK_ORDER"] == "1"
        ? [
            .linkedLibrary("plutovg", .when(platforms: [.linux])),
            .linkedLibrary("sharpyuv", .when(platforms: [.linux])),
        ]
        : []

let wasmtimeProducts: [Product] = [
    .library(name: "PluginWasmtimeRuntime", targets: ["PluginWasmtimeRuntime"]),
    .executable(name: "PluginRuntimeProbe", targets: ["PluginRuntimeProbe"]),
]
let wasmtimeTargets: [Target] = [
    .binaryTarget(name: "Wasmtime", path: "\(nativeArtifactRoot)/Wasmtime.artifactbundle"),
    .target(
        name: "CWasmtimeBridge",
        dependencies: ["Wasmtime"],
        path: "Sources/Bridge/CWasmtimeBridge",
        publicHeadersPath: "include",
        cSettings: [.define("WASM_API_EXTERN", to: ""), .define("WASI_API_EXTERN", to: "")],
        linkerSettings: [
            .linkedFramework("CoreFoundation", .when(platforms: [.macOS, .iOS])),
            .linkedLibrary("pthread", .when(platforms: [.linux])),
            .linkedLibrary("dl", .when(platforms: [.linux, .android])),
            .linkedLibrary("m", .when(platforms: [.linux, .android])),
            .linkedLibrary("ws2_32", .when(platforms: [.windows])),
            .linkedLibrary("advapi32", .when(platforms: [.windows])),
            .linkedLibrary("userenv", .when(platforms: [.windows])),
            .linkedLibrary("ntdll", .when(platforms: [.windows])),
            .linkedLibrary("shell32", .when(platforms: [.windows])),
            .linkedLibrary("ole32", .when(platforms: [.windows])),
            .linkedLibrary("bcrypt", .when(platforms: [.windows])),
        ]
    ),
    .target(name: "PluginWasmtimeRuntime", dependencies: [.product(name: "GuavaFileSystem", package: "GuavaUI"), "CWasmtimeBridge", "PluginRuntime"]),
    .executableTarget(name: "PluginRuntimeProbe", dependencies: ["PluginWasmtimeRuntime", "PluginRuntime"],
                      path: "Validation/Plugins/Swift"),
]

let package = Package(
    name: "GuavaStudioRuntime",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SIMDCompat", targets: ["SIMDCompat"]),
        .library(name: "EngineKernel", targets: ["EngineKernel"]),
        .library(name: "EngineMath", targets: ["EngineMath"]),
        .library(name: "RenderBackend", targets: ["RenderBackend"]),
        // Shared fixtures/readback tools for renderer and UI integration gates.
        .library(name: "NativeRendererValidation", targets: ["NativeRendererValidation"]),
        .executable(name: "NativeRHIPassProbe", targets: ["NativeRHIPassProbe"]),
        .library(name: "ObservationBus", targets: ["ObservationBus"]),
        .library(name: "SceneRuntime", targets: ["SceneRuntime"]),
        .library(name: "AssetPipeline", targets: ["AssetPipeline"]),
        .library(name: "SequenceRuntime", targets: ["SequenceRuntime"]),
        .library(name: "ColorPipeline", targets: ["ColorPipeline"]),
        .library(name: "EXRIO", targets: ["EXRIO"]),
        .library(name: "CinematicRenderer", targets: ["CinematicRenderer"]),
        .library(name: "CardBattleRuntime", targets: ["CardBattleRuntime"]),
        .library(name: "AudioRuntime", targets: ["AudioRuntime"]),
        .library(name: "CapabilityRuntime", targets: ["CapabilityRuntime"]),
        .library(name: "PluginRuntime", targets: ["PluginRuntime"]),
        .library(name: "LanguageServerRuntime", targets: ["LanguageServerRuntime"]),
        .library(name: "IntentRuntime", targets: ["IntentRuntime"]),
        .library(name: "PerceptionRuntime", targets: ["PerceptionRuntime"]),
        .library(name: "AIRuntime", targets: ["AIRuntime"]),
        .library(name: "ContextMemory", targets: ["ContextMemory"]),
        .library(name: "ScriptRuntime", targets: ["ScriptRuntime"]),
        .library(name: "SemanticPipeline", targets: ["SemanticPipeline"]),
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .executable(name: "SceneRuntimeBenchmarks", targets: ["SceneRuntimeBenchmarks"]),
        .executable(name: "PhysicsRuntimeBenchmarks", targets: ["PhysicsRuntimeBenchmarks"]),
        .executable(name: "RenderBackendBenchmarks", targets: ["RenderBackendBenchmarks"]),
        .executable(name: "StylizedCharacterPreviewDemo", targets: ["StylizedCharacterPreviewDemo"]),
        .executable(name: "GuavaPluginHost", targets: ["GuavaPluginHost"]),
    ],
    dependencies: [
        .package(name: "GuavaUI", path: sdkRoot),
        .package(path: "Media"),
    ],
    targets: [
        // MARK: - C Bridges


        .target(
            name: "CEngineBridge",
            dependencies: [.product(name: "CGuavaLog", package: "GuavaUI")],
            path: "Sources/Bridge/CEngineBridge",
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "Jolt",
            path: "\(nativeArtifactRoot)/Jolt.artifactbundle"
        ),
        .target(
            name: "CJoltBridge",
            dependencies: ["Jolt"],
            path: "Sources/Bridge/CJoltBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                // Must match Jolt's PUBLIC INTERFACE_COMPILE_DEFINITIONS from
                // JoltConfig.cmake (Release config). Mismatches cause undef
                // symbols at link or crashes at runtime.
                .define("NDEBUG"),
                .define("JPH_PROFILE_ENABLED"),
                .define("JPH_OBJECT_STREAM"),
                .define("JPH_OBJECT_LAYER_BITS", to: "16"),
            ]
        ),
        .target(
            name: "COpenEXRBridge",
            dependencies: ["ocio_openexr"],
            path: "Sources/Bridge/COpenEXRBridge",
            publicHeadersPath: "include"
        ),
        .binaryTarget(
            name: "ocio_openexr",
            path: "\(nativeArtifactRoot)/ocio_openexr.artifactbundle"
        ),




        // MARK: - SIMD compatibility shim (re-exports Apple simd on macOS, implements on other platforms)
        .target(name: "SIMDCompat"),

        // MARK: - Core Kernel (no deps, pure Swift protocols and types)
        .target(name: "EngineKernel", dependencies: [.product(name: "GuavaPlatformCore", package: "GuavaUI")]),
        .target(name: "EngineMath", dependencies: ["SIMDCompat"]),

        // MARK: - Rendering

        // MARK: - Platform

        // MARK: - Engine Services
        .target(name: "ObservationBus"),
        .target(
            name: "SceneRuntime",
            dependencies: [
                "SIMDCompat",
                "EngineKernel",
                "CJoltBridge",
            ]
        ),
        .target(
            name: "AssetPipeline",
            dependencies: [
                .product(name: "GuavaFileSystem", package: "GuavaUI"),
                "SIMDCompat",
                "SceneRuntime",
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
                .product(name: "GuavaLogging", package: "GuavaUI"),
            ],
            linkerSettings: nativeLinkOrderSettings
        ),
        .target(name: "SequenceRuntime"),
        .target(
            name: "ColorPipeline",
            dependencies: ["SIMDCompat"]
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
                "SIMDCompat",
                "SceneRuntime",
            ]
        ),
        .target(name: "CardBattleRuntime"),
        .target(
            name: "AudioRuntime",
            dependencies: [
                .product(name: "GuavaLogging", package: "GuavaUI"),
                "SIMDCompat",
                "SceneRuntime",
                // FFmpeg decodes media; SDL3 owns device output.
                .product(name: "MediaRuntime", package: "Media"),
                .product(name: "CSDL3", package: "GuavaUI"),
            ]
        ),
        .target(
            name: "AIRuntime",
            dependencies: [
                .product(name: "GuavaUIAgentCore", package: "GuavaUI"),
                "SIMDCompat",
                "SceneRuntime",
                "ScriptRuntime",
                "IntentRuntime",
                "ObservationBus",
                "ContextMemory",
                "PerceptionRuntime",
                "PluginRuntime",
            ]
        ),
        .target(
            name: "CapabilityRuntime",
            dependencies: [.product(name: "GuavaUIAgentCore", package: "GuavaUI")]
        ),
        .target(
            name: "PluginRuntime",
            dependencies: [.product(name: "GuavaFileSystem", package: "GuavaUI"), "CapabilityRuntime", .product(name: "GuavaProcess", package: "GuavaUI"), .product(name: "GuavaLogging", package: "GuavaUI")]
        ),
        .target(name: "LanguageServerRuntime", dependencies: [.product(name: "GuavaProcess", package: "GuavaUI"), .product(name: "GuavaLogging", package: "GuavaUI")]),
        .target(
            name: "IntentRuntime",
            dependencies: [
                "SIMDCompat",
                "AssetPipeline",
                "CapabilityRuntime",
                "ObservationBus",
                "SceneRuntime",
                "SequenceRuntime",
                "ScriptRuntime",
            ]
        ),
        .target(
            name: "ContextMemory",
            dependencies: [.product(name: "GuavaFileSystem", package: "GuavaUI"), "IntentRuntime"]
        ),
        .target(
            name: "PerceptionRuntime",
            dependencies: [.product(name: "GuavaFileSystem", package: "GuavaUI"),
                "IntentRuntime",
            ],
            linkerSettings: [
                .linkedFramework("Vision", .when(platforms: [.macOS])),
                .linkedFramework("CoreImage", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "ScriptRuntime",
            dependencies: [.product(name: "GuavaFileSystem", package: "GuavaUI"),
                "SIMDCompat",
                "EngineKernel",
                "AssetPipeline",
                "SceneRuntime",
            ]
        ),
        .target(name: "SemanticPipeline", dependencies: [.product(name: "GuavaFileSystem", package: "GuavaUI"), "IntentRuntime", "PerceptionRuntime"],
                linkerSettings: [
                    .linkedFramework("Vision", .when(platforms: [.macOS])),
                    .linkedFramework("CoreImage", .when(platforms: [.macOS])),
                ]),
        .target(
            name: "RenderBackend",
            dependencies: [
                "SIMDCompat",
                "EngineKernel",
                "EngineMath",
                .product(name: "NativeRHI", package: "GuavaUI"),
                "AssetPipeline",
                "SceneRuntime",
                .product(name: "GuavaLogging", package: "GuavaUI"),
            ],
            resources: [
                .copy("Resources/FinalBaseMesh.obj"),
                .copy("Resources/NativeSceneFixture.gltf"),
                .copy("Resources/Shaders"),
            ]
        ),

        // Pinned, offline syntax parser; only lib.c is compiled (it includes the runtime).
        .target(name: "CTreeSitter", path: "third-party/tree-sitter/lib",
                sources: ["src/lib.c"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("src"), .unsafeFlags(["-O2"])]),
        .target(name: "CTreeSitterSwift", dependencies: ["CTreeSitter"],
                path: "third-party/tree-sitter-swift",
                sources: ["src/parser.c", "src/scanner.c"], publicHeadersPath: "include",
                cSettings: [.headerSearchPath("src")]),

        // MARK: - Engine Host (orchestrates all services)
        .target(
            name: "EngineCore",
            dependencies: [.product(name: "GuavaLogging", package: "GuavaUI"),
                "CTreeSitter",
                "CTreeSitterSwift",
                "CEngineBridge",
                "EngineKernel",
                .product(name: "NativeRHI", package: "GuavaUI"),
                "RenderBackend",
                "SceneRuntime",
                "AssetPipeline",
                "AudioRuntime",
                "ScriptRuntime",
            ]
        ),
        .executableTarget(
            name: "SceneRuntimeBenchmarks",
            dependencies: [.product(name: "GuavaLogging", package: "GuavaUI"),
                "SIMDCompat",
                "SceneRuntime",
            ],
            path: "Benchmarks/SceneRuntimeBenchmarks"
        ),
        .executableTarget(
            name: "PhysicsRuntimeBenchmarks",
            dependencies: [.product(name: "GuavaLogging", package: "GuavaUI"),
                "SIMDCompat",
                "SceneRuntime",
            ],
            path: "Benchmarks/PhysicsRuntimeBenchmarks",
            linkerSettings: [
                .linkedLibrary("kernel32", .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(
            name: "RenderBackendBenchmarks",
            dependencies: [.product(name: "GuavaLogging", package: "GuavaUI"), "NativeRendererValidation"],
            path: "Benchmarks/RenderBackendBenchmarks"
        ),
        .executableTarget(
            name: "StylizedCharacterPreviewDemo",
            dependencies: [.product(name: "GuavaLogging", package: "GuavaUI"),
                "SIMDCompat",
                "RenderBackend",
                "SceneRuntime",
            ],
            path: "Demos/StylizedCharacterPreviewDemo"
        ),
        .executableTarget(
            name: "GuavaPluginHost",
            dependencies: [.product(name: "GuavaFileSystem", package: "GuavaUI"), .product(name: "GuavaLogging", package: "GuavaUI"),
                "CapabilityRuntime",
                "IntentRuntime",
                "PluginRuntime",
            ]
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: [
                "NativeRendererValidation",
                .product(name: "NativeRHI", package: "GuavaUI"),
                "SIMDCompat",
                "EngineCore",
                "EngineKernel",
                "EngineMath",
                "RenderBackend",
                "SceneRuntime",
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
            ]
        ),
        .testTarget(
            name: "EngineMathTests",
            dependencies: [
                "SIMDCompat",
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
                "SIMDCompat",
                "EngineKernel",
                "SceneRuntime",
                "ScriptRuntime",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ScriptRuntimeTests",
            dependencies: [
                "SIMDCompat",
                "ScriptRuntime",
                "SceneRuntime",
                "AssetPipeline",
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
            ],
            // The test loads compiled Swift scripts with dlopen; the host
            // executable must export the runtime symbols they reference.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "--export-dynamic"], .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "AssetPipelineTests",
            dependencies: [
                "SIMDCompat",
                "AssetPipeline",
                "SceneRuntime",
                // AssetPipeline imports the CImageDecodeBridge Clang module; test
                // targets that import AssetPipeline must see it too (the macOS
                // toolchain requires the Clang module transitively).
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
            ]
        ),
        .testTarget(
            name: "AudioRuntimeTests",
            dependencies: [
                "SIMDCompat",
                "SceneRuntime",
                "AudioRuntime",
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
            name: "CapabilityRuntimeTests",
            dependencies: [
                "CapabilityRuntime",
            ]
        ),
        .testTarget(
            name: "PluginRuntimeTests",
            dependencies: [
                .product(name: "GuavaLogging", package: "GuavaUI"),
                "CapabilityRuntime",
                "PluginRuntime",
                .product(name: "GuavaProcess", package: "GuavaUI"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "IntentRuntimeTests",
            dependencies: [
                "SIMDCompat",
                "IntentRuntime",
                "AssetPipeline",
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
                "CapabilityRuntime",
                "ObservationBus",
                "SceneRuntime",
                "ScriptRuntime",
                "SequenceRuntime",
            ]
        ),
        .testTarget(
            name: "SemanticPipelineTests",
            dependencies: [
                "IntentRuntime",
                "SemanticPipeline",
                // Transitively imports AssetPipeline → the CImageDecodeBridge
                // Clang module must be a direct test-target dep on macOS.
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
            ]
        ),
        .testTarget(
            name: "PerceptionRuntimeTests",
            dependencies: [
                "IntentRuntime",
                "PerceptionRuntime",
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
            ]
        ),
        .testTarget(
            name: "AIRuntimeTests",
            dependencies: [
                "AIRuntime",
                "CapabilityRuntime",
                "ContextMemory",
                "IntentRuntime",
                "PerceptionRuntime",
                "PluginRuntime",
                "ScriptRuntime",
                "SIMDCompat",
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
            ]
        ),
        .testTarget(
            name: "ContextMemoryTests",
            dependencies: [
                "ContextMemory",
                "IntentRuntime",
                .product(name: "ImageDecodeBridge", package: "GuavaUI"),
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
                "SIMDCompat",
                "CinematicRenderer",
            ]
        ),
        .executableTarget(name: "NativeRHIPassProbe",
            dependencies: [.product(name: "GuavaLogging", package: "GuavaUI"), "NativeRendererValidation"]),
        .target(name: "NativeRendererValidation",
            dependencies: ["RenderBackend", .product(name: "NativeRHI", package: "GuavaUI"), "SceneRuntime", "EngineKernel", "SIMDCompat", "AssetPipeline"]),
        .testTarget(name: "NativeRendererTests",
            dependencies: ["NativeRendererValidation", "RenderBackend", .product(name: "NativeRHI", package: "GuavaUI"), "SceneRuntime", "EngineKernel", "SIMDCompat", "AssetPipeline"]),

    ],
    cxxLanguageStandard: .cxx17
)

package.products.append(contentsOf: wasmtimeProducts)
package.targets.append(contentsOf: wasmtimeTargets)
for targetName in ["GuavaPluginHost", "PluginRuntimeTests"] {
    package.targets.first(where: { $0.name == targetName })?
        .dependencies.append("PluginWasmtimeRuntime")
}
