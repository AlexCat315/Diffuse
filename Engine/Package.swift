// swift-tools-version: 6.1
// GuavaStudioRuntime 0.0.9
import PackageDescription
import Foundation

// Cross builds stage target archives separately from the host's vendor directory.
let nativeArtifactRoot = ProcessInfo.processInfo.environment["GUAVA_ENGINE_ARTIFACT_ROOT"] ?? "vendor"

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
    .target(name: "PluginWasmtimeRuntime", dependencies: ["CWasmtimeBridge", "PluginRuntime"]),
    .executableTarget(name: "PluginRuntimeProbe", dependencies: ["PluginWasmtimeRuntime", "PluginRuntime"],
                      path: "Validation/Plugins/Swift"),
]

// Vulkan targets native Windows/Linux/Android drivers. macOS uses Metal and has no
// Vulkan loader, headers, portability surface, or driver dependency.
#if os(Windows) || os(Linux)
// Native hosts use the installed Vulkan SDK; set VULKAN_SDK for non-system paths.
let vulkanSDKRoot = ProcessInfo.processInfo.environment["VULKAN_SDK"]
let vulkanIncludeFlags = vulkanSDKRoot.map { ["-I", $0 + "/Include", "-I", $0 + "/include"] } ?? []
let vulkanLibraryFlags = vulkanSDKRoot.map { ["-L", $0 + "/Lib", "-L", $0 + "/lib"] } ?? []
#else
let vulkanIncludeFlags: [String] = []
let vulkanLibraryFlags: [String] = []
#endif
// A manifest executes on the host. Conditional target dependencies also cover
// a macOS host cross-compiling for Android with the NDK sysroot.
let nativeRHIInteropDependencies: [Target.Dependency] = [
    .target(name: "CVulkanHeaders", condition: .when(platforms: [.windows, .linux, .android])), "CDX12Bridge",
]
let nativeRHIInteropTargets: [Target] = [
    .target(name: "CVulkanHeaders", path: "Sources/Bridge/CVulkanHeaders", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(vulkanIncludeFlags)],
            linkerSettings: [.unsafeFlags(vulkanLibraryFlags),
                .linkedLibrary("vulkan-1", .when(platforms: [.windows])),
                .linkedLibrary("vulkan", .when(platforms: [.linux, .android]))])
]

let package = Package(
    name: "GuavaStudioRuntime",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SIMDCompat", targets: ["SIMDCompat"]),
        .library(name: "EngineKernel", targets: ["EngineKernel"]),
        .library(name: "EngineMath", targets: ["EngineMath"]),
        .library(name: "NativeRHI", targets: ["NativeRHI"]),
        .library(name: "PlatformShell", targets: ["PlatformShell"]),
        .library(name: "ImageDecodeBridge", targets: ["CImageDecodeBridge"]),
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
        .library(name: "ProcessRuntime", targets: ["ProcessRuntime"]),
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
        .package(path: "../GuavaUI/Portable"),
        .package(path: "PlatformCore"),
        .package(path: "Logging"),
        .package(path: "Media"),
    ],
    targets: [
        // MARK: - C Bridges
        .target(
            name: "CDX12Bridge", path: "Sources/Bridge/CDX12Bridge",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-fexceptions"])],
            linkerSettings: [
                .linkedLibrary("d3d12", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                .linkedLibrary("dxguid", .when(platforms: [.windows])),
            ]
        ),
        .binaryTarget(
            name: "SDL3",
            path: "\(nativeArtifactRoot)/SDL3.artifactbundle"
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
                .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
                .linkedFramework("UniformTypeIdentifiers", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("CoreBluetooth", .when(platforms: [.iOS])),
                .linkedFramework("Foundation", .when(platforms: [.iOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.iOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.iOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.iOS])),
                .linkedFramework("CoreGraphics", .when(platforms: [.iOS])),
                .linkedFramework("CoreHaptics", .when(platforms: [.iOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.iOS])),
                .linkedFramework("CoreMotion", .when(platforms: [.iOS])),
                .linkedFramework("CoreVideo", .when(platforms: [.iOS])),
                .linkedFramework("GameController", .when(platforms: [.iOS])),
                .linkedFramework("Metal", .when(platforms: [.iOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.iOS])),
                .linkedFramework("OpenGLES", .when(platforms: [.iOS])),
                // SDL3 static needs these Win32 system libraries at link time.
                .linkedLibrary("winmm", .when(platforms: [.windows])),
                .linkedLibrary("setupapi", .when(platforms: [.windows])),
                .linkedLibrary("imm32", .when(platforms: [.windows])),
                .linkedLibrary("version", .when(platforms: [.windows])),
                .linkedLibrary("ole32", .when(platforms: [.windows])),
                .linkedLibrary("oleaut32", .when(platforms: [.windows])),
                .linkedLibrary("uuid", .when(platforms: [.windows])),
                .linkedLibrary("advapi32", .when(platforms: [.windows])),
                .linkedLibrary("shell32", .when(platforms: [.windows])),
                .linkedLibrary("user32", .when(platforms: [.windows])),
                .linkedLibrary("gdi32", .when(platforms: [.windows])),
                .linkedLibrary("android", .when(platforms: [.android])),
                .linkedLibrary("log", .when(platforms: [.android])),
                .linkedLibrary("OpenSLES", .when(platforms: [.android])),
                .linkedLibrary("aaudio", .when(platforms: [.android])),
                .linkedLibrary("EGL", .when(platforms: [.android])),
                .linkedLibrary("GLESv2", .when(platforms: [.android])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("d3d12", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "CEngineBridge",
            dependencies: [.product(name: "CGuavaLog", package: "Logging")],
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
        .binaryTarget(
            name: "lunasvg",
            path: "\(nativeArtifactRoot)/lunasvg.artifactbundle"
        ),
        .binaryTarget(
            name: "plutovg",
            path: "\(nativeArtifactRoot)/plutovg.artifactbundle"
        ),
        .binaryTarget(
            name: "webp",
            path: "\(nativeArtifactRoot)/webp.artifactbundle"
        ),
        .binaryTarget(
            name: "sharpyuv",
            path: "\(nativeArtifactRoot)/sharpyuv.artifactbundle"
        ),
        .target(
            name: "CImageDecodeBridge",
            dependencies: [
                "lunasvg",
                "plutovg",
                "webp",
                "sharpyuv",
            ],
            path: "Sources/Bridge/CImageDecodeBridge",
            publicHeadersPath: "include",
            // SwiftPM passes these binary archives by their full paths, in
            // dependency order (lunasvg before plutovg). Additional -l flags
            // lack the artifact search paths and break Swift 6.4 Linux links.
            cxxSettings: [
                .define("LUNASVG_BUILD_STATIC"),
            ]
        ),

        // MARK: - SIMD compatibility shim (re-exports Apple simd on macOS, implements on other platforms)
        .target(name: "SIMDCompat"),

        // MARK: - Core Kernel (no deps, pure Swift protocols and types)
        .target(name: "EngineKernel", dependencies: [.product(name: "GuavaPlatformCore", package: "PlatformCore")]),
        .target(name: "EngineMath", dependencies: ["SIMDCompat"]),

        // MARK: - Rendering
        .target(
            name: "NativeRHI",
            dependencies: nativeRHIInteropDependencies + [.product(name: "GuavaLogging", package: "Logging")],
            path: "Sources/NativeRHI",
            exclude: ["docs"]
        ),

        // MARK: - Platform
        .target(
            name: "PlatformShell",
            dependencies: [
                .product(name: "GuavaPlatformCore", package: "PlatformCore"),
                "CSDL3",
                "EngineKernel",
                .product(name: "GuavaLogging", package: "Logging"),
            ]
        ),

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
                "SIMDCompat",
                "SceneRuntime",
                "CImageDecodeBridge",
                .product(name: "GuavaLogging", package: "Logging"),
            ]
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
                .product(name: "GuavaLogging", package: "Logging"),
                "SIMDCompat",
                "SceneRuntime",
                // FFmpeg decodes media; SDL3 owns device output.
                .product(name: "MediaRuntime", package: "Media"),
                "CSDL3",
            ]
        ),
        .target(
            name: "AIRuntime",
            dependencies: [
                .product(name: "GuavaUIAgentCore", package: "Portable"),
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
            dependencies: [.product(name: "GuavaUIAgentCore", package: "Portable")]
        ),
        .target(
            name: "PluginRuntime",
            dependencies: ["CapabilityRuntime", "ProcessRuntime", .product(name: "GuavaLogging", package: "Logging")]
        ),
        .target(name: "ProcessRuntime"),
        .target(name: "LanguageServerRuntime", dependencies: ["ProcessRuntime", .product(name: "GuavaLogging", package: "Logging")]),
        .testTarget(name: "ProcessRuntimeTests", dependencies: ["ProcessRuntime"]),
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
            dependencies: ["IntentRuntime"]
        ),
        .target(
            name: "PerceptionRuntime",
            dependencies: [
                "IntentRuntime",
            ],
            linkerSettings: [
                .linkedFramework("Vision", .when(platforms: [.macOS])),
                .linkedFramework("CoreImage", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "ScriptRuntime",
            dependencies: [
                "SIMDCompat",
                "EngineKernel",
                "AssetPipeline",
                "SceneRuntime",
            ]
        ),
        .target(name: "SemanticPipeline", dependencies: ["IntentRuntime", "PerceptionRuntime"],
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
                "NativeRHI",
                "AssetPipeline",
                "SceneRuntime",
                .product(name: "GuavaLogging", package: "Logging"),
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
            dependencies: [.product(name: "GuavaLogging", package: "Logging"),
                "CTreeSitter",
                "CTreeSitterSwift",
                "CEngineBridge",
                "EngineKernel",
                "NativeRHI",
                "RenderBackend",
                "SceneRuntime",
                "AssetPipeline",
                "AudioRuntime",
                "ScriptRuntime",
            ]
        ),
        .executableTarget(
            name: "SceneRuntimeBenchmarks",
            dependencies: [.product(name: "GuavaLogging", package: "Logging"),
                "SIMDCompat",
                "SceneRuntime",
            ],
            path: "Benchmarks/SceneRuntimeBenchmarks"
        ),
        .executableTarget(
            name: "PhysicsRuntimeBenchmarks",
            dependencies: [.product(name: "GuavaLogging", package: "Logging"),
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
            dependencies: [.product(name: "GuavaLogging", package: "Logging"), "NativeRendererValidation"],
            path: "Benchmarks/RenderBackendBenchmarks"
        ),
        .executableTarget(
            name: "StylizedCharacterPreviewDemo",
            dependencies: [.product(name: "GuavaLogging", package: "Logging"),
                "SIMDCompat",
                "RenderBackend",
                "SceneRuntime",
            ],
            path: "Demos/StylizedCharacterPreviewDemo"
        ),
        .executableTarget(
            name: "GuavaPluginHost",
            dependencies: [.product(name: "GuavaLogging", package: "Logging"),
                "CapabilityRuntime",
                "IntentRuntime",
                "PluginRuntime",
            ]
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: [
                "NativeRendererValidation",
                "NativeRHI",
                "SIMDCompat",
                "EngineCore",
                "EngineKernel",
                "EngineMath",
                "RenderBackend",
                "SceneRuntime",
                "CImageDecodeBridge",
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
                "CImageDecodeBridge",
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
                "CImageDecodeBridge",
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
                .product(name: "GuavaLogging", package: "Logging"),
                "CapabilityRuntime",
                "PluginRuntime",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "IntentRuntimeTests",
            dependencies: [
                "SIMDCompat",
                "IntentRuntime",
                "AssetPipeline",
                "CImageDecodeBridge",
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
                "CImageDecodeBridge",
            ]
        ),
        .testTarget(
            name: "PerceptionRuntimeTests",
            dependencies: [
                "IntentRuntime",
                "PerceptionRuntime",
                "CImageDecodeBridge",
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
                "CImageDecodeBridge",
            ]
        ),
        .testTarget(
            name: "ContextMemoryTests",
            dependencies: [
                "ContextMemory",
                "IntentRuntime",
                "CImageDecodeBridge",
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
            dependencies: [.product(name: "GuavaLogging", package: "Logging"), "NativeRendererValidation"]),
        .target(name: "NativeRendererValidation",
            dependencies: ["RenderBackend", "NativeRHI", "SceneRuntime", "EngineKernel", "SIMDCompat", "AssetPipeline"]),
        .testTarget(name: "NativeRendererTests",
            dependencies: ["NativeRendererValidation", "RenderBackend", "NativeRHI", "SceneRuntime", "EngineKernel", "SIMDCompat", "AssetPipeline"]),
        .testTarget(
            name: "NativeRHITests",
            dependencies: [
                "NativeRHI",
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)

package.products.append(contentsOf: wasmtimeProducts)
package.targets.append(contentsOf: wasmtimeTargets)
package.targets.append(contentsOf: nativeRHIInteropTargets)
for targetName in ["GuavaPluginHost", "PluginRuntimeTests"] {
    package.targets.first(where: { $0.name == targetName })?
        .dependencies.append("PluginWasmtimeRuntime")
}

// macOS builds the package's tests as one bundle: SwiftPM's synthesized
// `GuavaStudioRuntimePackageTests` runner links every test target and transitively
// loads AssetPipeline, which imports the CImageDecodeBridge Clang module. The
// macOS explicit-module build then requires that module's modulemap in scope
// for the whole bundle — not just the test targets that import AssetPipeline
// directly. Declaring it per-target never converges (the runner is synthesized
// and cannot take an explicit dependency), so apply the rule uniformly: every
// test target depends on CImageDecodeBridge. (Lenient toolchains — Windows /
// Linux — do not need this, but the extra dependency is harmless there.)
for target in package.targets where target.isTest {
    if !target.dependencies.contains(where: { dependency in
        if case let .targetItem(name, _) = dependency { return name == "CImageDecodeBridge" }
        if case let .byNameItem(name, _) = dependency { return name == "CImageDecodeBridge" }
        return false
    }) {
        target.dependencies.append("CImageDecodeBridge")
    }
}
