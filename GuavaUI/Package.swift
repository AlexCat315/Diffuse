// swift-tools-version: 6.1
// GuavaUI 0.0.1
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
        // v2 runtime, rebuilt from scratch. Pure Swift, no deps, coexists with
        // the legacy GuavaUI targets until it reaches parity and the editor
        // switches over. See Sources/GuavaKit/Architecture.md.
        .library(name: "GuavaKit", targets: ["GuavaKit"]),
        // Bridge: translates GuavaKit → legacy DrawList, hosts SDL/wgpu loop.
        .library(name: "GuavaKitHost", targets: ["GuavaKitHost"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
        .package(url: "https://github.com/facebook/yoga.git", from: "3.0.0"),
    ],
    targets: [
        // MARK: - Native deps (built by GuavaUI/third-party/CMakeLists.txt)
        .binaryTarget(
            name: "CFreeType",
            path: "vendor/CFreeType.artifactbundle"
        ),
        .binaryTarget(
            name: "CHarfBuzz",
            path: "vendor/CHarfBuzz.artifactbundle"
        ),

        // MARK: - Yoga C bridge
        // Wraps the yoga SPM source package with a flat module map so that
        // GuavaUIRuntime can use `import CYoga` and access all YG* symbols.
        .target(
            name: "CYoga",
            dependencies: [.product(name: "yoga", package: "yoga")],
            path: "Sources/Bridge/CYoga",
            publicHeadersPath: "include"
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
            dependencies: ["GuavaUICompose", "GuavaUIRuntime"],
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
            dependencies: [
                "GuavaUIRuntime",
                "GuavaUICompose",
                "GuavaUIWorkspace",
                .product(name: "CardBattleRuntime", package: "Engine"),
            ]
        ),

        // MARK: - GuavaKit (v2 runtime, rebuilt from scratch)
        // Pure Swift, zero external dependencies — so it builds fast, is easy to
        // reason about, and can be developed/tested in isolation from the legacy
        // stack. The whole point of the rewrite lives here.
        .target(
            name: "GuavaKit",
            path: "Sources/GuavaKit",
            exclude: ["Architecture.md"]
        ),

        // Bridge: translates GuavaKit's backend-agnostic DisplayList into the
        // existing GuavaUIRuntime DrawList (reusing the whole wgpu pipeline), and
        // will host the run loop / event adapter for the editor switchover.
        .target(
            name: "GuavaKitHost",
            dependencies: ["GuavaKit", "GuavaUIRuntime"],
            path: "Sources/GuavaKitHost"
        ),

        // MARK: - Tests
        .testTarget(
            name: "GuavaKitTests",
            dependencies: ["GuavaKit"]
        ),
        .testTarget(
            name: "GuavaKitHostTests",
            dependencies: ["GuavaKitHost", "GuavaKit", "GuavaUIRuntime"]
        ),
        .testTarget(
            name: "GuavaUIRuntimeTests",
            dependencies: [
                "GuavaUIRuntime",
                "GuavaUIBundledFonts",
                .product(name: "PlatformShell", package: "Engine"),
            ]
        ),
        .testTarget(
            name: "GuavaUIComposeTests",
            dependencies: [
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
