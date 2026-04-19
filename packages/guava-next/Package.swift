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
        .library(name: "EngineKernel", targets: ["EngineKernel"]),
        .library(name: "RHIWGPU", targets: ["RHIWGPU"]),
        .library(name: "SceneRuntime", targets: ["SceneRuntime"]),
        .library(name: "AssetPipeline", targets: ["AssetPipeline"]),
        .library(name: "ScriptRuntime", targets: ["ScriptRuntime"]),
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
            name: "CWGPUBridge",
            path: "Sources/CWGPUBridge",
            publicHeadersPath: "include"
        ),
        .target(name: "EngineKernel"),
        .target(
            name: "RHIWGPU",
            dependencies: ["CWGPUBridge"]
        ),
        .target(name: "SceneRuntime"),
        .target(name: "AssetPipeline"),
        .target(name: "ScriptRuntime"),
        .target(
            name: "EngineCore",
            dependencies: [
                "CEngineBridge",
                "EngineKernel",
                "RHIWGPU",
                "SceneRuntime",
                "AssetPipeline",
                "ScriptRuntime",
            ]
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
