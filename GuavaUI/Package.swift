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
            dependencies: ["GuavaUIRuntime"]
        ),

        // MARK: - Demo
        .executableTarget(
            name: "GuavaUIDemo",
            dependencies: ["GuavaUIRuntime", "GuavaUICompose"]
        ),

        // MARK: - Tests
        .testTarget(
            name: "GuavaUIRuntimeTests",
            dependencies: ["GuavaUIRuntime"]
        ),
        .testTarget(
            name: "GuavaUIComposeTests",
            dependencies: [
                "GuavaUICompose",
                "GuavaUIRuntime",
                .product(name: "EngineKernel", package: "Engine"),
            ]
        ),
    ]
)
