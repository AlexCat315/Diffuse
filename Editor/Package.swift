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
        // 编辑器状态、面板、Dock 布局，使用 GuavaUI Compose 构建 UI。
        .target(
            name: "EditorCore",
            dependencies: [
                .product(name: "EngineCore", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
                .product(name: "PlatformShell", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "GuavaUICompose", package: "GuavaUI"),
            ]
        ),

        // MARK: - Editor Entry Point
        .executableTarget(
            name: "EditorApp",
            dependencies: [
                "EditorCore",
                .product(name: "PlatformShell", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
            ]
        ),
    ]
)
