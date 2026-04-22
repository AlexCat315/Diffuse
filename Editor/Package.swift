// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GuavaEditor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EditorApp", targets: ["EditorApp"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
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
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "SceneRuntime", package: "Engine"),
                .product(name: "GuavaUIRuntime", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
            ]
        ),

        // MARK: - Editor Entry Point
        .executableTarget(
            name: "EditorApp",
            dependencies: [
                "EditorCore",
                .product(name: "GuavaUIApp", package: "GuavaUI"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
                .product(name: "RHIWGPU", package: "Engine"),
            ]
        ),
    ]
)
