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
        .library(name: "PlatformShell", targets: ["PlatformShell"]),
    ],
    targets: [
        .target(
            name: "CEngineBridge",
            path: "Sources/Bridge/CEngineBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CWGPUBridge",
            path: "Sources/Bridge/CWGPUBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../../vendor/wgpu/include")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "vendor/wgpu/lib",
                    "-lwgpu_native",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../vendor/wgpu/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../vendor/wgpu/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/wgpu/lib",
                ])
            ]
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
        .target(
            name: "RenderBackend",
            dependencies: ["RHIWGPU", "PlatformShell", "AssetPipeline"],
            resources: [.copy("Resources/FinalBaseMesh.obj")]
        ),
        .target(
            name: "EditorCore",
            dependencies: ["EngineCore", "RenderBackend"]
        ),
        .target(name: "PlatformShell"),
        .executableTarget(
            name: "EditorApp",
            dependencies: ["EditorCore", "PlatformShell"]
        ),
    ]
)
