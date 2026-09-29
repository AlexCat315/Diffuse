// swift-tools-version: 6.1
// GuavaEditor 0.0.1
import PackageDescription

// MARK: - C ABI exports for dynamically loaded Swift scripts
//
// Swift scripts compiled out-of-process are loaded as dynamic libraries and
// call back into the engine through `@_cdecl("guava_*")` functions. On Windows
// the linker does not export symbols by default, so each host executable must
// explicitly export the symbols scripts may call via `/EXPORT:` flags.
//
// Keep this list in sync with the `@_cdecl` declarations in
// `Engine/Sources/ScriptRuntime/DynamicScript/ScriptCBridge*.swift`.
// You can regenerate it with `SwiftScriptCompiler.scanExportedSymbols(in:)`.
let guavaExportedSymbols: [String] = [
    "guava_character_ground_state",
    "guava_character_is_grounded",
    "guava_character_velocity",
    "guava_delta_time",
    "guava_input_axis",
    "guava_input_held",
    "guava_input_just_pressed",
    "guava_input_just_released",
    "guava_submit_character_command",
]

/// Linker settings that export the `guava_*` C ABI symbols from a Windows
/// executable so dynamically loaded script libraries can import them.
let guavaScriptExportLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        guavaExportedSymbols.flatMap { ["-Xlinker", "/EXPORT:\($0)"] },
        .when(platforms: [.windows])
    ),
]

let package = Package(
    name: "GuavaEditor",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "EditorApp", targets: ["EditorApp"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "GameRuntime", targets: ["GameRuntime"]),
        .executable(name: "GuavaPlayer", targets: ["GuavaPlayer"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(path: "../GuavaUI"),
    ],
    targets: [
        // MARK: - Editor Domain
        // 编辑器状态、Store、引擎宿主。UI 通过 GuavaUICompose 构建，
        // 窗口/wgpu 装配交给 EditorApp 那一层依赖的 GuavaUIApp。
        .target(
            name: "EditorCore",
            dependencies: [
                .product(name: "SIMDCompat", package: "Engine"),
                .product(name: "AIRuntime", package: "Engine"),
                .product(name: "ContextMemory", package: "Engine"),
                .product(name: "AssetPipeline", package: "Engine"),
                .product(name: "AudioRuntime", package: "Engine"),
                .product(name: "CapabilityRuntime", package: "Engine"),
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "EngineMath", package: "Engine"),
                .product(name: "IntentRuntime", package: "Engine"),
                .product(name: "ObservationBus", package: "Engine"),
                .product(name: "PerceptionRuntime", package: "Engine"),
                .product(name: "PluginRuntime", package: "Engine"),
                .product(name: "SemanticPipeline", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "SceneRuntime", package: "Engine"),
                .product(name: "ScriptRuntime", package: "Engine"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS])),
            ]
        ),

        // MARK: - Editor Entry Point
        .executableTarget(
            name: "EditorApp",
            dependencies: [
                "EditorCore",
                .product(name: "SIMDCompat", package: "Engine"),
                .product(name: "AssetPipeline", package: "Engine"),
                .product(name: "GuavaUIApp", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
                .product(name: "GuavaUIWorkspace", package: "GuavaUI"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
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
            linkerSettings: guavaScriptExportLinkerSettings
        ),
        // MARK: - Game Runtime (simulation host, no Editor UI)
        // 独立游戏播放器的引擎宿主层。依赖 EditorCore（场景加载）和
        // EngineCore（引擎宿主），但不依赖任何编辑器 UI 模块。
        .target(
            name: "GameRuntime",
            dependencies: [
                "EditorCore",
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
            ]
        ),

        // MARK: - Standalone Game Player
        .executableTarget(
            name: "GuavaPlayer",
            dependencies: [
                "GameRuntime",
                .product(name: "GuavaUIApp", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
            ],
            linkerSettings: guavaScriptExportLinkerSettings
        ),

        .testTarget(
            name: "EditorCoreTests",
            dependencies: [
                "EditorCore",
                .product(name: "SIMDCompat", package: "Engine"),
                .product(name: "CapabilityRuntime", package: "Engine"),
                .product(name: "PluginRuntime", package: "Engine"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
            ]
        ),

        .testTarget(
            name: "EditorAppTests",
            dependencies: [
                "EditorApp",
                "EditorCore",
            ]
        ),

        .testTarget(
            name: "GameRuntimeTests",
            dependencies: ["GameRuntime"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
