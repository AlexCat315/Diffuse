// swift-tools-version: 6.4
// DiffuseRuntime 0.0.9
import PackageDescription
import Foundation

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Editor").standardizedFileURL
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cove.json"))) as! [String: Any]
let requiredSDK = (document["toolchain"] as! [String: String])["sdkVersion"]!
let environment = ProcessInfo.processInfo.environment
#if os(Windows)
let sdkHome = environment["COVE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: environment["LOCALAPPDATA"]!).appendingPathComponent("Cove")
#elseif os(Linux)
let sdkHome = environment["COVE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: environment["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path).appendingPathComponent("cove")
#else
let sdkHome = environment["COVE_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cove")
#endif
func sdkSelection(_ file: URL) -> URL? {
    guard let data = try? Data(contentsOf: file),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let path = value["path"] else { return nil }
    return URL(fileURLWithPath: path)
}
func sdkVersion(_ root: URL) -> String? {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path),
          let data = try? Data(contentsOf: root.appendingPathComponent("Tools/Cove/Sources/CoveCLI/SDK.json")),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
    return value["version"]
}
let overrideSDK = environment["COVE_SDK_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? sdkSelection(directory.appendingPathComponent(".cove/sdk.json"))
let selectedSDK = sdkSelection(sdkHome.appendingPathComponent("sdk.json"))
let installedSDKs = (try? FileManager.default.contentsOfDirectory(at: sdkHome.appendingPathComponent("versions"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
let candidates = ([selectedSDK].compactMap { $0 } + installedSDKs).filter { sdkVersion($0) != nil }
let resolvedSDK = overrideSDK ?? (requiredSDK == "latest"
    ? candidates.max { sdkVersion($0)!.compare(sdkVersion($1)!, options: .numeric) == .orderedAscending }
    : candidates.first { sdkVersion($0) == requiredSDK })
guard let resolvedSDK, let actualSDK = sdkVersion(resolvedSDK),
      environment["COVE_SDK_ROOT"] != nil || requiredSDK == "latest" || requiredSDK == actualSDK else {
    fatalError("Install the shared Cove SDK with cove sdk install \(requiredSDK), then select it with cove sdk use VERSION or PATH")
}

let sdkRoot = resolvedSDK.resolvingSymlinksInPath().path

// Cross builds stage target archives separately from the host's vendor directory.
let nativeArtifactRoot = ProcessInfo.processInfo.environment["COVE_ENGINE_ARTIFACT_ROOT"] ?? "vendor"

// GNU ld resolves static archives in one pass, while SwiftPM's native build
// system emits artifact-bundle libraries in no dependency order. CI enables
// this only for native builds; Swift Build already passes the artifacts as
// ordered absolute paths and would reject the bare -l flags.
let nativeLinkOrderSettings: [LinkerSetting] =
    ProcessInfo.processInfo.environment["COVE_NATIVE_LINK_ORDER"] == "1"
        ? [
            .linkedLibrary("plutovg", .when(platforms: [.linux])),
            .linkedLibrary("sharpyuv", .when(platforms: [.linux])),
        ]
        : []

let package = Package(
    name: "DiffuseRuntime",
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
        .executable(name: "DiffusePluginHost", targets: ["DiffusePluginHost"]),
    ],
    dependencies: [
        .package(name: "CoveUI", path: sdkRoot),
        .package(path: "Media"),
        .package(url: "https://github.com/AlexCat315/Natsel.git", branch: "main"),
    ],
    targets: [
        // MARK: - C Bridges


        .target(
            name: "CEngineBridge",
            dependencies: [.product(name: "CCoveLog", package: "CoveUI")],
            path: "Sources/Bridge/CEngineBridge",
            publicHeadersPath: "include"
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
        .target(name: "EngineKernel", dependencies: [.product(name: "CovePlatformCore", package: "CoveUI")]),
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
                .product(name: "Natsel", package: "Natsel"),
            ]
        ),
        .target(
            name: "AssetPipeline",
            dependencies: [
                .product(name: "CoveFileSystem", package: "CoveUI"),
                "SIMDCompat",
                "SceneRuntime",
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
                .product(name: "CoveLogging", package: "CoveUI"),
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
                .product(name: "CoveLogging", package: "CoveUI"),
                "SIMDCompat",
                "SceneRuntime",
                // FFmpeg decodes media; SDL3 owns device output.
                .product(name: "MediaRuntime", package: "Media"),
                .product(name: "CSDL3", package: "CoveUI"),
            ]
        ),
        .target(
            name: "AIRuntime",
            dependencies: [
                .product(name: "CoveUIAgentCore", package: "CoveUI"),
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
            dependencies: [.product(name: "CoveUIAgentCore", package: "CoveUI")]
        ),
        .target(
            name: "PluginRuntime",
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"), "CapabilityRuntime", .product(name: "CoveProcess", package: "CoveUI"), .product(name: "CoveLogging", package: "CoveUI")],
            resources: [.copy("Resources")]
        ),
        .target(name: "LanguageServerRuntime", dependencies: [.product(name: "CoveProcess", package: "CoveUI"), .product(name: "CoveLogging", package: "CoveUI")]),
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
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"), "IntentRuntime"]
        ),
        .target(
            name: "PerceptionRuntime",
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"),
                "IntentRuntime",
            ],
            linkerSettings: [
                .linkedFramework("Vision", .when(platforms: [.macOS])),
                .linkedFramework("CoreImage", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "ScriptRuntime",
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"),
                "SIMDCompat",
                "EngineKernel",
                "AssetPipeline",
                "SceneRuntime",
            ]
        ),
        .target(name: "SemanticPipeline", dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"), "IntentRuntime", "PerceptionRuntime"],
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
                .product(name: "NativeRHI", package: "CoveUI"),
                "AssetPipeline",
                "SceneRuntime",
                .product(name: "CoveLogging", package: "CoveUI"),
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
            dependencies: [.product(name: "CoveLogging", package: "CoveUI"),
                "CTreeSitter",
                "CTreeSitterSwift",
                "CEngineBridge",
                "EngineKernel",
                .product(name: "NativeRHI", package: "CoveUI"),
                "RenderBackend",
                "SceneRuntime",
                "AssetPipeline",
                "AudioRuntime",
                "ScriptRuntime",
            ]
        ),
        .executableTarget(
            name: "SceneRuntimeBenchmarks",
            dependencies: [.product(name: "CoveLogging", package: "CoveUI"),
                "SIMDCompat",
                "SceneRuntime",
            ],
            path: "Benchmarks/SceneRuntimeBenchmarks"
        ),
        .executableTarget(
            name: "PhysicsRuntimeBenchmarks",
            dependencies: [.product(name: "CoveLogging", package: "CoveUI"),
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
            dependencies: [.product(name: "CoveLogging", package: "CoveUI"), "NativeRendererValidation"],
            path: "Benchmarks/RenderBackendBenchmarks"
        ),
        .executableTarget(
            name: "StylizedCharacterPreviewDemo",
            dependencies: [.product(name: "CoveLogging", package: "CoveUI"),
                "SIMDCompat",
                "RenderBackend",
                "SceneRuntime",
            ],
            path: "Demos/StylizedCharacterPreviewDemo"
        ),
        .executableTarget(
            name: "DiffusePluginHost",
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"), .product(name: "CoveLogging", package: "CoveUI"),
                "CapabilityRuntime",
                "IntentRuntime",
                "PluginRuntime",
            ]
        ),
        .testTarget(
            name: "EngineCoreTests",
            dependencies: [
                "NativeRendererValidation",
                .product(name: "NativeRHI", package: "CoveUI"),
                "SIMDCompat",
                "EngineCore",
                "EngineKernel",
                "EngineMath",
                "RenderBackend",
                "SceneRuntime",
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
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
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
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
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
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
                .product(name: "CoveLogging", package: "CoveUI"),
                "CapabilityRuntime",
                "PluginRuntime",
                .product(name: "CoveProcess", package: "CoveUI"),
            ]
        ),
        .testTarget(
            name: "IntentRuntimeTests",
            dependencies: [
                "SIMDCompat",
                "IntentRuntime",
                "AssetPipeline",
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
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
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
            ]
        ),
        .testTarget(
            name: "PerceptionRuntimeTests",
            dependencies: [
                "IntentRuntime",
                "PerceptionRuntime",
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
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
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
            ]
        ),
        .testTarget(
            name: "ContextMemoryTests",
            dependencies: [
                "ContextMemory",
                "IntentRuntime",
                .product(name: "ImageDecodeBridge", package: "CoveUI"),
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
            dependencies: [.product(name: "CoveLogging", package: "CoveUI"), "NativeRendererValidation"]),
        .target(name: "NativeRendererValidation",
            dependencies: ["RenderBackend", .product(name: "NativeRHI", package: "CoveUI"), "SceneRuntime", "EngineKernel", "SIMDCompat", "AssetPipeline"]),
        .testTarget(name: "NativeRendererTests",
            dependencies: ["NativeRendererValidation", "RenderBackend", .product(name: "NativeRHI", package: "CoveUI"), "SceneRuntime", "EngineKernel", "SIMDCompat", "AssetPipeline"]),

    ],
    cxxLanguageStandard: .cxx17
)

