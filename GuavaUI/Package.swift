// swift-tools-version: 6.1
// GuavaUI 0.0.9
import PackageDescription

let package = Package(
    name: "GuavaUI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GuavaUIDemo", targets: ["GuavaUIDemo"]),
        .library(name: "GuavaUIRuntime", targets: ["GuavaUIRuntime"]),
        .library(name: "GuavaUICompose", targets: ["GuavaUICompose"]),
        .library(name: "GuavaUIWorkspace", targets: ["GuavaUIWorkspace"]),
        .library(name: "GuavaUIApp", targets: ["GuavaUIApp"]),
        .library(name: "GuavaUIDevTools", targets: ["GuavaUIDevTools"]),
        .library(name: "GuavaUIGallery", targets: ["GuavaUIGallery"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(path: "Portable"),
        .package(path: "Text"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    ],
    targets: [
        // MARK: - Runtime
        // 平台层、布局引擎、文字渲染、节点树、recompose 运行时。
        // 依赖 Engine 的渲染抽象（RHIWGPU、PlatformShell、EngineKernel）。
        .target(
            name: "GuavaUIRuntime",
            dependencies: [
                .product(name: "GuavaUICore", package: "Portable"),
                .product(name: "CYoga", package: "Portable"),
                .product(name: "GuavaUIScene", package: "Portable"),
                .product(name: "GuavaUIText", package: "Text"),
                .product(name: "CFreeType", package: "Text"),
                .product(name: "CHarfBuzz", package: "Text"),
                "GuavaUIBundledFonts",
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "PlatformShell", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "ImageDecodeBridge", package: "Engine"),
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: [
                // winmm provides timeBeginPeriod/timeEndPeriod, used by the run
                // loop to raise the Windows timer resolution so Thread.sleep
                // pacing isn't quantized to ~15.6ms (which caps fps at 64).
                .linkedLibrary("winmm", .when(platforms: [.windows])),
            ]
        ),

        // MARK: - Compose
        // 声明式 API、状态系统、modifier、layout composable、组件集合。
        // 不依赖 Engine，只依赖 GuavaUIRuntime。
        .target(
            name: "GuavaUICompose",
            dependencies: ["GuavaUIRuntime",
                           .product(name: "GuavaUIComposeCore", package: "Portable"),
                           .product(name: "EngineKernel", package: "Engine"),
                           .product(name: "RenderBackend", package: "Engine")],
            resources: [
                .process("Resources"),
            ]
        ),

        // MARK: - Workspace
        // Production workspace/dock model and renderer. Keeps editor-style
        // panel semantics out of Compose primitives and App hosting.
        .target(
            name: "GuavaUIWorkspace",
            dependencies: [
                "GuavaUICompose",
                "GuavaUIRuntime",
                .product(name: "EngineKernel", package: "Engine"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),

        // MARK: - Bundled fonts
        // Font shim target. No font is bundled — each platform uses its system
        // default UI font (see SystemFontDefaults / FontProvider).
        .target(
            name: "GuavaUIBundledFonts",
            path: "Sources/Font"
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
                "GuavaUIWorkspace",
                "GuavaUIDevTools",
                "GuavaUIBundledFonts",
                .product(name: "PlatformShell", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),

        // MARK: - DevTools
        // 进程内跨平台 WebSocket 调试服务器。传输和协议位于 Portable 包。
        // 仅依赖 GuavaUIRuntime 的只读快照接口，opt-in。
        .target(
            name: "GuavaUIDevTools",
            dependencies: [
                .product(name: "GuavaUIDevToolsServer", package: "Portable"),
                .product(name: "GuavaUIDevToolsScene", package: "Portable"),
                .product(name: "GuavaUIDevToolsProtocol", package: "Portable"),
                "GuavaUIRuntime",
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RHIWGPU", package: "Engine"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - Demo
        .target(
            name: "GuavaUIGallery",
            dependencies: ["GuavaUICompose", "GuavaUIWorkspace"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "GuavaUIDemo",
            dependencies: [
                .product(name: "GuavaUISharedDemo", package: "Portable"),
                "GuavaUIRuntime",
                "GuavaUICompose",
                "GuavaUIWorkspace",
                "GuavaUIDevTools",
                "GuavaUIGallery",
            ]
        ),

        // MARK: - Tests
        .testTarget(name: "GuavaUIGalleryTests", dependencies: ["GuavaUIGallery", "GuavaUICompose"]),
        .testTarget(
            name: "GuavaUIRuntimeTests",
            dependencies: [
                .product(name: "GuavaUIScene", package: "Portable"),
                "GuavaUIRuntime",
                "GuavaUIBundledFonts",
                .product(name: "PlatformShell", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "GuavaUIComposeTests",
            dependencies: [
                .product(name: "GuavaUIComposeCore", package: "Portable"),
                "GuavaUICompose",
                "GuavaUIRuntime",
                "GuavaUIBundledFonts",
                .product(name: "EngineKernel", package: "Engine"),
                .product(name: "RenderBackend", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "GuavaUIAppTests",
            dependencies: [
                "GuavaUIApp",
                "GuavaUICompose",
                "GuavaUIWorkspace",
            ]
        ),
        .testTarget(
            name: "GuavaUIWorkspaceTests",
            dependencies: [
                "GuavaUIWorkspace",
                "GuavaUICompose",
                "GuavaUIRuntime",
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
