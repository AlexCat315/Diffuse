// swift-tools-version: 6.4
// DiffuseEditor 0.0.9
import Foundation
import PackageDescription

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
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

// MARK: - C ABI exports for dynamically loaded Swift scripts
//
// Swift scripts compiled out-of-process are loaded as dynamic libraries and
// call back into the engine through `@_cdecl("cove_*")` functions. On Windows
// the linker does not export symbols by default, so each host executable must
// explicitly export the symbols scripts may call via `/EXPORT:` flags.
//
// Keep this list in sync with the `@_cdecl` declarations in
// `Engine/Sources/ScriptRuntime/DynamicScript/ScriptCBridge*.swift`.
// You can regenerate it with `SwiftScriptCompiler.scanExportedSymbols(in:)`.
let coveExportedSymbols: [String] = [
    "cove_character_ground_state",
    "cove_character_is_grounded",
    "cove_character_velocity",
    "cove_delta_time",
    "cove_input_axis",
    "cove_input_held",
    "cove_input_just_pressed",
    "cove_input_just_released",
    "cove_submit_character_command",
]

/// Expose host Swift symbols to gameplay libraries on macOS/Linux and the
/// existing C ABI surface on Windows.
let coveScriptExportLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-export_dynamic"], .when(platforms: [.macOS])),
    .unsafeFlags(["-Xlinker", "--export-dynamic"], .when(platforms: [.linux])),
    .unsafeFlags(
        coveExportedSymbols.flatMap { ["-Xlinker", "/EXPORT:\($0)"] },
        .when(platforms: [.windows])
    ),
]

/// Test bundles that dlopen compiled scripts must export the host runtime
/// symbols those libraries reference. Linux needs this because the native
/// build system does not add `--export-dynamic` on its own.
let coveTestDlopenLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "--export-dynamic"], .when(platforms: [.linux])),
]

let package = Package(
    name: "DiffuseEditor",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .executable(name: "EditorApp", targets: ["EditorApp"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "EditorUI", targets: ["EditorUI"]),
        .library(name: "GameRuntime", targets: ["GameRuntime"]),
        .executable(name: "CoveProjectExport", targets: ["CoveProjectExport"]),
        .executable(name: "CovePlayer", targets: ["CovePlayer"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(path: "../Engine/Media"),
        .package(path: "Documents"),
        .package(name: "CoveUI", path: sdkRoot),
    ],
    targets: [
        // MARK: - Editor Domain
        // 编辑器状态、Store、引擎宿主。UI 通过 CoveUICompose 构建，
        // 窗口/NativeRHI 装配交给 EditorApp 那一层依赖的 CoveUI。
        .target(
            name: "EditorCore",
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"), .product(name: "CoveLogging", package: "CoveUI"),
                .product(name: "SIMDCompat", package: "Engine"),
                .product(name: "AIRuntime", package: "Engine"),
                .product(name: "ContextMemory", package: "Engine"),
                .product(name: "AssetPipeline", package: "Engine"),
                .product(name: "AudioRuntime", package: "Engine"),
                .product(name: "StudioDocuments", package: "Documents"),
                .product(name: "MediaRuntime", package: "Media"),
                .product(name: "CapabilityRuntime", package: "Engine"),
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "EngineMath", package: "Engine"),
                .product(name: "IntentRuntime", package: "Engine"),
                .product(name: "ObservationBus", package: "Engine"),
                .product(name: "PerceptionRuntime", package: "Engine"),
                .product(name: "PluginRuntime", package: "Engine"),
                .product(name: "CoveProcess", package: "CoveUI"),
                .product(name: "LanguageServerRuntime", package: "Engine"),
                .product(name: "SemanticPipeline", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "NativeRHI", package: "CoveUI"),
                .product(name: "SceneRuntime", package: "Engine"),
                .product(name: "ScriptRuntime", package: "Engine"),
                .product(name: "CoveUIRuntime", package: "CoveUI"),
                .product(name: "CoveUICompose", package: "CoveUI"),
                .product(name: "CoveUIAgent", package: "CoveUI"),
            ],
            resources: [
                .process("Resources/ProjectTemplates"),
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
                .copy("Resources/Plugins")
            ],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),

        // MARK: - Editor Entry Point
        .target(
            name: "EditorUI",
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"), .product(name: "CoveLogging", package: "CoveUI"),
                "EditorCore",
                .product(name: "PluginRuntime", package: "Engine"),
                .product(name: "AudioRuntime", package: "Engine"),
                .product(name: "StudioDocuments", package: "Documents"),
                .product(name: "MediaRuntime", package: "Media"),
                .product(name: "SIMDCompat", package: "Engine"),
                .product(name: "AssetPipeline", package: "Engine"),
                .product(name: "CoveUI", package: "CoveUI"),
                .product(name: "CoveUICompose", package: "CoveUI"),
                .product(name: "CoveUIWorkspace", package: "CoveUI"),
                .product(name: "CoveUITerminal", package: "CoveUI"),
                .product(name: "CoveUIRuntime", package: "CoveUI"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "NativeRHI", package: "CoveUI"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "SceneRuntime", package: "Engine"),
                .product(name: "CardBattleRuntime", package: "Engine"),
                .product(name: "CinematicRenderer", package: "Engine"),
                .product(name: "ColorPipeline", package: "Engine"),
                .product(name: "EXRIO", package: "Engine"),
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.enableUpcomingFeature("InternalImportsByDefault")]
        ),
        .executableTarget(name: "EditorApp", dependencies: ["EditorUI"], linkerSettings: coveScriptExportLinkerSettings),
        // MARK: - Game Runtime (simulation host, no Editor UI)
        // 独立游戏播放器的引擎宿主层。依赖 EditorCore（场景加载）和
        // EngineCore（引擎宿主），但不依赖任何编辑器 UI 模块。
        .target(
            name: "GameRuntime",
            dependencies: [.product(name: "CoveFileSystem", package: "CoveUI"), .product(name: "CoveLogging", package: "CoveUI"),
                "EditorCore",
                .product(name: "ScriptRuntime", package: "Engine"),
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "NativeRHI", package: "CoveUI"),
            ]
        ),

        .executableTarget(name: "CoveProjectExport", dependencies: [.product(name: "CoveLogging", package: "CoveUI"), "EditorCore"]),

        // MARK: - Standalone Game Player
        .executableTarget(
            name: "CovePlayer",
            dependencies: [.product(name: "CoveLogging", package: "CoveUI"),
                "GameRuntime", "EditorCore",
                .product(name: "CoveUI", package: "CoveUI"),
                .product(name: "CoveUICompose", package: "CoveUI"),
                .product(name: "CoveUIRuntime", package: "CoveUI"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "NativeRHI", package: "CoveUI"),
            ],
            linkerSettings: coveScriptExportLinkerSettings
        ),

        .executableTarget(name: "LanguageServerFixture", dependencies: [
            .product(name: "CoveProcess", package: "CoveUI"),
            .product(name: "CoveFileSystem", package: "CoveUI"),
        ], path: "Tests/Fixtures/LanguageServer"),
        .testTarget(
            name: "EditorCoreTests",

            dependencies: [
                .product(name: "NativeRendererValidation", package: "Engine"),
                .product(name: "NativeRHI", package: "CoveUI"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "CoveUI", package: "CoveUI"),
                .product(name: "CoveLogging", package: "CoveUI"),
                "EditorCore",
                .product(name: "AIRuntime", package: "Engine"),
                .product(name: "SIMDCompat", package: "Engine"),
                .product(name: "CapabilityRuntime", package: "Engine"),
                .product(name: "PluginRuntime", package: "Engine"),
                .product(name: "PluginWasmtimeRuntime", package: "Engine"),
                .product(name: "CoveUICompose", package: "CoveUI"),
                .product(name: "CoveUIRuntime", package: "CoveUI"),
            ]
        ),

        .testTarget(
            name: "ScriptSystemTests",
            dependencies: [
                "EditorCore",
                .product(name: "ScriptRuntime", package: "Engine"),
            ]
        ),

        .testTarget(
            name: "EditorAppTests",
            dependencies: [
                "EditorUI",
                "EditorCore",
            ]
        ),

        .testTarget(
            name: "EditorWorkbenchTests",
            dependencies: [
                "EditorUI",
                "EditorCore",
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "SceneRuntime", package: "Engine"),
                .product(name: "CoveUI", package: "CoveUI"),
                .product(name: "CoveUICompose", package: "CoveUI"),
                .product(name: "CoveUIRuntime", package: "CoveUI"),
                .product(name: "CoveUIWorkspace", package: "CoveUI"),
            ],
            linkerSettings: coveTestDlopenLinkerSettings
        ),

        .testTarget(
            name: "GameRuntimeTests",
            dependencies: [
                "GameRuntime",
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "NativeRHI", package: "CoveUI"),
                .product(name: "RenderBackend", package: "Engine"),
            ],
            linkerSettings: coveTestDlopenLinkerSettings
        ),
    ],
    cxxLanguageStandard: .cxx17
)
