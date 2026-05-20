// swift-tools-version: 6.1
// GuavaEngine 0.0.1
import PackageDescription
import Foundation

// Engine package's absolute path — needed for linkerSettings.unsafeFlags so that
// Editor / GuavaUI can find vendored dylibs even when this package is consumed
// from a different working directory.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

#if os(macOS)
  #if arch(arm64)
  let guavaTriple = "macos-arm64"
  #else
  let guavaTriple = "macos-x86_64"
  #endif
#elseif os(Windows)
let guavaTriple = "windows-x86_64"
#elseif os(Linux)
  #if arch(arm64)
  let guavaTriple = "linux-aarch64"
  #else
  let guavaTriple = "linux-x86_64"
  #endif
#else
let guavaTriple = "unknown"
#endif

let ocioOpenEXRLibDir = "\(packageDir)/vendor/ocio_openexr/\(guavaTriple)/lib"
let ocioOpenEXRIncDir = "\(packageDir)/vendor/ocio_openexr/\(guavaTriple)/include"

let package = Package(
    name: "GuavaEngine",
    products: [
        .library(name: "SIMDCompat", targets: ["SIMDCompat"]),
        .library(name: "EngineKernel", targets: ["EngineKernel"]),
        .library(name: "EngineMath", targets: ["EngineMath"]),
        .library(name: "RHIWGPU", targets: ["RHIWGPU"]),
        .library(name: "PlatformShell", targets: ["PlatformShell"]),
        .library(name: "ImageDecodeBridge", targets: ["CImageDecodeBridge"]),
        .library(name: "RenderBackend", targets: ["RenderBackend"]),
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
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("d3d12", .when(platforms: [.windows])),
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
                // wgpu_native (static) needs these Win32 system libraries.
                .linkedLibrary("d3d12", .when(platforms: [.windows])),
                .linkedLibrary("d3d11", .when(platforms: [.windows])),
                .linkedLibrary("dxgi", .when(platforms: [.windows])),
                .linkedLibrary("dxguid", .when(platforms: [.windows])),
                .linkedLibrary("userenv", .when(platforms: [.windows])),
                .linkedLibrary("ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("bcrypt", .when(platforms: [.windows])),
                .linkedLibrary("ntdll", .when(platforms: [.windows])),
                .linkedLibrary("opengl32", .when(platforms: [.windows])),
                .linkedLibrary("propsys", .when(platforms: [.windows])),
            ]
        ),
        .binaryTarget(
            name: "Jolt",
            path: "vendor/Jolt.artifactbundle"
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
            path: "Sources/Bridge/COpenEXRBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../../vendor/ocio_openexr/\(guavaTriple)/include"),
                .headerSearchPath("../../../vendor/ocio_openexr/\(guavaTriple)/include/OpenEXR"),
                .headerSearchPath("../../../vendor/ocio_openexr/\(guavaTriple)/include/Imath"),
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
                    "-lopenjph",
                    "-Xlinker", "-rpath", "-Xlinker", ocioOpenEXRLibDir,
                ], .when(platforms: [.macOS])),
                .unsafeFlags([
                    "\(ocioOpenEXRLibDir)/OpenEXR-3_4.lib",
                    "\(ocioOpenEXRLibDir)/OpenEXRUtil-3_4.lib",
                    "\(ocioOpenEXRLibDir)/OpenEXRCore-3_4.lib",
                    "\(ocioOpenEXRLibDir)/Iex-3_4.lib",
                    "\(ocioOpenEXRLibDir)/IlmThread-3_4.lib",
                    "\(ocioOpenEXRLibDir)/Imath-3_2.lib",
                    "\(ocioOpenEXRLibDir)/openjph.0.24.lib",
                    "-Xlinker", "/NODEFAULTLIB:openjph.lib",
                ], .when(platforms: [.windows])),
                .unsafeFlags([
                    "-L\(ocioOpenEXRLibDir)",
                    "-lOpenEXR-3_4",
                    "-lOpenEXRUtil-3_4",
                    "-lOpenEXRCore-3_4",
                    "-lIex-3_4",
                    "-lIlmThread-3_4",
                    "-lImath-3_2",
                    "-lopenjph",
                ], .when(platforms: [.linux])),
            ]
        ),
        .binaryTarget(
            name: "lunasvg",
            path: "vendor/lunasvg.artifactbundle"
        ),
        .binaryTarget(
            name: "plutovg",
            path: "vendor/plutovg.artifactbundle"
        ),
        .binaryTarget(
            name: "webp",
            path: "vendor/webp.artifactbundle"
        ),
        .binaryTarget(
            name: "sharpyuv",
            path: "vendor/sharpyuv.artifactbundle"
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
            cxxSettings: [
                .define("LUNASVG_BUILD_STATIC"),
            ]
        ),

        // MARK: - SIMD compatibility shim (re-exports Apple simd on macOS, implements on other platforms)
        .target(name: "SIMDCompat"),

        // MARK: - Core Kernel (no deps, pure Swift protocols and types)
        .target(name: "EngineKernel"),
        .target(name: "EngineMath", dependencies: ["SIMDCompat"]),

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
                "SIMDCompat",
                "EngineKernel",
                "CJoltBridge",
            ]
        ),
        .target(name: "AssetPipeline", dependencies: ["SIMDCompat"]),
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
            dependencies: ["SceneRuntime"],
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.macOS])),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "AIRuntime",
            dependencies: [
                "SIMDCompat",
                "SceneRuntime",
                "IntentRuntime",
            ]
        ),
        .target(
            name: "CapabilityRuntime"
        ),
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
            name: "ScriptRuntime",
            dependencies: [
                "SIMDCompat",
                "EngineKernel",
                "AssetPipeline",
                "SceneRuntime",
            ]
        ),
        .target(
            name: "RenderBackend",
            dependencies: [
                "SIMDCompat",
                "EngineKernel",
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
                "AudioRuntime",
                "ScriptRuntime",
            ]
        ),
        .executableTarget(
            name: "SceneRuntimeBenchmarks",
            dependencies: [
                "SIMDCompat",
                "SceneRuntime",
            ],
            path: "Benchmarks/SceneRuntimeBenchmarks"
        ),
        .executableTarget(
            name: "RenderBackendBenchmarks",
            dependencies: [
                "SIMDCompat",
                "RenderBackend",
                "RHIWGPU",
                "SceneRuntime",
            ],
            path: "Benchmarks/RenderBackendBenchmarks"
        ),
        .executableTarget(
            name: "StylizedCharacterPreviewDemo",
            dependencies: [
                "SIMDCompat",
                "RenderBackend",
                "RHIWGPU",
                "SceneRuntime",
            ],
            path: "Demos/StylizedCharacterPreviewDemo"
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: [
                "SIMDCompat",
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
            ]
        ),
        .testTarget(
            name: "ScriptRuntimeTests",
            dependencies: [
                "SIMDCompat",
                "ScriptRuntime",
                "SceneRuntime",
            ]
        ),
        .testTarget(
            name: "AssetPipelineTests",
            dependencies: [
                "SIMDCompat",
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
            name: "CapabilityRuntimeTests",
            dependencies: [
                "CapabilityRuntime",
            ]
        ),
        .testTarget(
            name: "IntentRuntimeTests",
            dependencies: [
                "SIMDCompat",
                "IntentRuntime",
                "AssetPipeline",
                "CapabilityRuntime",
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
                "SIMDCompat",
                "CinematicRenderer",
            ]
        ),

        // MARK: - Plugins
        .plugin(
            name: "BuildNativeDeps",
            capability: .command(
                intent: .custom(
                    verb: "build-native-deps",
                    description: "Build Engine C/C++ dependencies (SDL3, Jolt, OpenEXR/Imath) via CMake"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes compiled artifact bundles to vendor/")
                ]
            )
        ),
    ],
    cxxLanguageStandard: .cxx17
)
