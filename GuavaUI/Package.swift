// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let yogaLibDir = "\(packageDir)/vendor/yoga/lib"
let yogaIncDir = "\(packageDir)/vendor/yoga/include"

let package = Package(
    name: "GuavaUI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "GuavaUIDemo", targets: ["GuavaUIDemo"]),
        .library(name: "GuavaUIRuntime", targets: ["GuavaUIRuntime"]),
        .library(name: "GuavaUICompose", targets: ["GuavaUICompose"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
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

        // MARK: - Runtime
        // 平台层、布局引擎、文字渲染、节点树、recompose 运行时。
        // 依赖 Engine 的渲染抽象（RHIWGPU、PlatformShell、EngineKernel）。
        .target(
            name: "GuavaUIRuntime",
            dependencies: [
                "CYoga",
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "PlatformShell", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
            ]
        ),

        // MARK: - Compose
        // 声明式 API、状态系统、modifier、layout composable、组件集合。
        // 不依赖 Engine，只依赖 GuavaUIRuntime。
        .target(
            name: "GuavaUICompose",
            dependencies: ["GuavaUIRuntime"]
        ),

        // MARK: - Demo
        .executableTarget(
            name: "GuavaUIDemo",
            dependencies: ["GuavaUIRuntime"]
        ),

        // MARK: - Tests
        .testTarget(
            name: "GuavaUIRuntimeTests",
            dependencies: ["GuavaUIRuntime"]
        ),
    ]
)
