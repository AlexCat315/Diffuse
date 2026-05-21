// swift-tools-version: 6.1
// GuavaEditor 0.0.1
import PackageDescription

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
                .product(name: "AssetPipeline", package: "Engine"),
                .product(name: "AudioRuntime", package: "Engine"),
                .product(name: "CapabilityRuntime", package: "Engine"),
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "IntentRuntime", package: "Engine"),
                .product(name: "ObservationBus", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "SceneRuntime", package: "Engine"),
                .product(name: "ScriptRuntime", package: "Engine"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
            ],
            resources: [
                .process("Resources")
            ]
        ),

        // MARK: - Editor Entry Point
        .executableTarget(
            name: "EditorApp",
            dependencies: [
                "EditorCore",
                .product(name: "SIMDCompat", package: "Engine"),
                .product(name: "GuavaUIApp", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
                .product(name: "GuavaUIWorkspace", package: "GuavaUI"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
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
            ]
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
            ]
        ),

        .testTarget(
            name: "EditorCoreTests",
            dependencies: [
                "EditorCore",
                .product(name: "SIMDCompat", package: "Engine"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
