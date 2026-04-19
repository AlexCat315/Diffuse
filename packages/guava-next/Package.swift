// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GuavaNext",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EditorApp", targets: ["EditorApp"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "EngineCore", targets: ["EngineCore"]),
        .library(name: "RenderBackend", targets: ["RenderBackend"]),
        .library(name: "PlatformShell", targets: ["PlatformShell"])
    ],
    targets: [
        .target(
            name: "CEngineBridge",
            path: "Sources/CEngineBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "EngineCore",
            dependencies: ["CEngineBridge"]
        ),
        .target(name: "RenderBackend"),
        .target(
            name: "EditorCore",
            dependencies: ["EngineCore", "RenderBackend"]
        ),
        .target(name: "PlatformShell"),
        .executableTarget(
            name: "EditorApp",
            dependencies: ["EditorCore", "PlatformShell"]
        )
    ]
)
