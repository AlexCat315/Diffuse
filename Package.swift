// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GuavaEngineWorkspace",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "EditorApp", targets: ["EditorApp"]),
    ],
    dependencies: [
        .package(path: "Engine"),
        .package(path: "GuavaUI"),
    ],
    targets: [
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
                .product(name: "EngineMath", package: "Engine"),
                .product(name: "IntentRuntime", package: "Engine"),
                .product(name: "ObservationBus", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "SceneRuntime", package: "Engine"),
                .product(name: "ScriptRuntime", package: "Engine"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
            ],
            path: "Editor/Sources/EditorCore",
            resources: [
                .process("Resources"),
            ]
        ),
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
            path: "Editor/Sources/EditorApp",
            resources: [
                .process("Resources"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
