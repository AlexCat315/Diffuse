// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Resolve the absolute path to the Engine package directory so that linker
// search paths work correctly whether this package is built standalone or as
// a dependency of Editor / other packages.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let wgpuLibDir = "\(packageDir)/vendor/wgpu/lib"

let package = Package(
    name: "GuavaEngine",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "EngineKernel", targets: ["EngineKernel"]),
        .library(name: "RHIWGPU", targets: ["RHIWGPU"]),
        .library(name: "PlatformShell", targets: ["PlatformShell"]),
        .library(name: "RenderBackend", targets: ["RenderBackend"]),
        .library(name: "SceneRuntime", targets: ["SceneRuntime"]),
        .library(name: "AssetPipeline", targets: ["AssetPipeline"]),
        .library(name: "ScriptRuntime", targets: ["ScriptRuntime"]),
        .library(name: "EngineCore", targets: ["EngineCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // MARK: - C Bridges
        .systemLibrary(
            name: "CSDL3",
            path: "Sources/Bridge/CSDL3",
            pkgConfig: "sdl3",
            providers: [
                .brew(["sdl3", "pkg-config"])
            ]
        ),
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
                    "-L", wgpuLibDir,
                    "-lwgpu_native",
                    "-Xlinker", "-rpath", "-Xlinker", wgpuLibDir,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../vendor/wgpu/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../vendor/wgpu/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/wgpu/lib",
                ])
            ]
        ),

        // MARK: - Core Kernel (no deps, pure Swift protocols and types)
        .target(name: "EngineKernel"),

        // MARK: - Rendering
        .target(
            name: "RHIWGPU",
            dependencies: [
                "CWGPUBridge",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - Platform
        .target(
            name: "PlatformShell",
            dependencies: [
                "CSDL3",
                "EngineKernel",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - Engine Services
        .target(name: "SceneRuntime"),
        .target(name: "AssetPipeline"),
        .target(name: "ScriptRuntime"),
        .target(
            name: "RenderBackend",
            dependencies: [
                "RHIWGPU",
                "PlatformShell",
                "AssetPipeline",
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.copy("Resources/FinalBaseMesh.obj")]
        ),

        // MARK: - Engine Host (orchestrates all services)
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
    ]
)
