// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let yogaLibDir = "\(packageDir)/vendor/yoga/lib"
let freetypeLibDir = "\(packageDir)/vendor/freetype/lib"
let harfbuzzLibDir = "\(packageDir)/vendor/harfbuzz/lib"

let package = Package(
    name: "GuavaUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GuavaUIDemo", targets: ["GuavaUIDemo"]),
        .library(name: "GuavaUIRuntime", targets: ["GuavaUIRuntime"]),
        .library(name: "GuavaUICompose", targets: ["GuavaUICompose"]),
        .library(name: "GuavaUIApp", targets: ["GuavaUIApp"]),
        .library(name: "GuavaUIDevTools", targets: ["GuavaUIDevTools"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // MARK: - Yoga C bridge (vendored static lib)
        .target(
            name: "CYoga",
            path: "Sources/CYoga",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", yogaLibDir]),
                .linkedLibrary("yoga"),
                .linkedLibrary("c++"),   // Yoga is compiled as C++
            ]
        ),

        // MARK: - FreeType C bridge (vendored static lib)
        .target(
            name: "CFreeType",
            path: "Sources/CFreeType",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", freetypeLibDir]),
                .linkedLibrary("freetype"),
                .linkedLibrary("z"),
            ]
        ),

        // MARK: - HarfBuzz C bridge (vendored static lib)
        .target(
            name: "CHarfBuzz",
            dependencies: ["CFreeType"],
            path: "Sources/CHarfBuzz",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", harfbuzzLibDir]),
                .linkedLibrary("harfbuzz"),
                .linkedLibrary("c++"),
            ]
        ),

        // MARK: - Runtime
        // 平台层、布局引擎、文字渲染、节点树、recompose 运行时。
        // 依赖 Engine 的渲染抽象（RHIWGPU、PlatformShell、EngineKernel）。
        .target(
            name: "GuavaUIRuntime",
            dependencies: [
                "CYoga",
                "CFreeType",
                "CHarfBuzz",
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "PlatformShell", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - Compose
        // 声明式 API、状态系统、modifier、layout composable、组件集合。
        // 不依赖 Engine，只依赖 GuavaUIRuntime。
        .target(
            name: "GuavaUICompose",
            dependencies: ["GuavaUIRuntime",
                           .product(name: "EngineKernel", package: "Engine"),
                           .product(name: "RenderBackend", package: "Engine")]
        ),

        // MARK: - App
        // 高层应用宿主：把 Runtime（窗口、wgpu、文本）和 Compose 装配在一起，
        // 对调用方暴露 `AppRuntime.run(...)` 一行启动入口。Editor / 第三方 App
        // 应优先依赖这一层，而不是直接拼装 SDL3PlatformHost + WGPUBackend。
        .target(
            name: "GuavaUIApp",
            dependencies: [
                "GuavaUIRuntime",
                "GuavaUICompose",
                "GuavaUIDevTools",
                .product(name: "PlatformShell", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - DevTools
        // 进程内 WebSocket 调试服务器。基于 Network.framework，无第三方依赖。
        // 仅依赖 GuavaUIRuntime 的只读快照接口，opt-in。
        .target(
            name: "GuavaUIDevTools",
            dependencies: [
                "GuavaUIRuntime",
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - Demo
        .executableTarget(
            name: "GuavaUIDemo",
            dependencies: ["GuavaUIRuntime", "GuavaUICompose"]
        ),

        // MARK: - Tests
        .testTarget(
            name: "GuavaUIRuntimeTests",
            dependencies: [
                "GuavaUIRuntime",
                .product(name: "PlatformShell", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "GuavaUIComposeTests",
            dependencies: [
                "GuavaUICompose",
                "GuavaUIRuntime",
                .product(name: "EngineKernel", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "GuavaUIAppTests",
            dependencies: [
                "GuavaUIApp",
                "GuavaUICompose",
            ]
        ),
        .testTarget(
            name: "GuavaUIDevToolsTests",
            dependencies: [
                "GuavaUIDevTools",
                "GuavaUIRuntime",
            ]
        ),
    ]
)
