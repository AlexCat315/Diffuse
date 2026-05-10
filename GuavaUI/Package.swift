// swift-tools-version: 6.0
// GuavaUI 0.0.1
import PackageDescription

let package = Package(
    name: "GuavaUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "GuavaUIDemo", targets: ["GuavaUIDemo"]),
        .library(name: "GuavaUIRuntime", targets: ["GuavaUIRuntime"]),
        .library(name: "GuavaUICompose", targets: ["GuavaUICompose"]),
        .library(name: "GuavaUIWorkspace", targets: ["GuavaUIWorkspace"]),
        .library(name: "GuavaUIApp", targets: ["GuavaUIApp"]),
        .library(name: "GuavaUIDevTools", targets: ["GuavaUIDevTools"]),
    ],
    dependencies: [
        .package(path: "../Engine"),
        .package(name: "yoga", path: "Sources/CYoga/upstream"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // MARK: - FreeType (built from source via submodule at Sources/CFreeType/upstream)
        .target(
            name: "CFreeType",
            path: "Sources/CFreeType",
            exclude: [
                "upstream/.github",
                "upstream/CMakeLists.txt",
                "upstream/Makefile",
                "upstream/configure",
                "upstream/autogen.sh",
                "upstream/MSBuild.rsp",
                "upstream/MSBuild.sln",
                "upstream/README",
                "upstream/README.git",
                "upstream/builds",
                "upstream/devel",
                "upstream/docs",
                "upstream/objs",
                "upstream/subprojects",
                "upstream/vms_make.com",
                "upstream/meson.build",
                "upstream/meson_options.txt",
                "upstream/src/tools",
                "upstream/src/dlg",
            ],
            sources: [
                "upstream/src/base/ftsystem.c",
                "upstream/src/base/ftinit.c",
                "upstream/src/base/ftdebug.c",
                "upstream/src/base/ftbase.c",
                "upstream/src/base/ftbbox.c",
                "upstream/src/base/ftbitmap.c",
                "upstream/src/base/ftcid.c",
                "upstream/src/base/ftfstype.c",
                "upstream/src/base/ftgasp.c",
                "upstream/src/base/ftglyph.c",
                "upstream/src/base/ftgxval.c",
                "upstream/src/base/ftmm.c",
                "upstream/src/base/ftotval.c",
                "upstream/src/base/ftpatent.c",
                "upstream/src/base/ftpfr.c",
                "upstream/src/base/ftstroke.c",
                "upstream/src/base/ftsynth.c",
                "upstream/src/base/fttype1.c",
                "upstream/src/base/ftwinfnt.c",
                "upstream/src/autofit/autofit.c",
                "upstream/src/bdf/bdf.c",
                "upstream/src/bzip2/ftbzip2.c",
                "upstream/src/cache/ftcache.c",
                "upstream/src/cff/cff.c",
                "upstream/src/cid/type1cid.c",
                "upstream/src/gzip/ftgzip.c",
                "upstream/src/gxvalid/gxvalid.c",
                "upstream/src/lzw/ftlzw.c",
                "upstream/src/otvalid/otvalid.c",
                "upstream/src/pcf/pcf.c",
                "upstream/src/pfr/pfr.c",
                "upstream/src/psaux/psaux.c",
                "upstream/src/pshinter/pshinter.c",
                "upstream/src/psnames/psnames.c",
                "upstream/src/raster/raster.c",
                "upstream/src/sdf/sdf.c",
                "upstream/src/sfnt/sfnt.c",
                "upstream/src/smooth/smooth.c",
                "upstream/src/svg/svg.c",
                "upstream/src/truetype/truetype.c",
                "upstream/src/type1/type1.c",
                "upstream/src/type42/type42.c",
                "upstream/src/winfonts/winfnt.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("FT2_BUILD_LIBRARY"),
                .headerSearchPath("upstream/include"),
            ]
        ),

        // MARK: - HarfBuzz (built from source via submodule at Sources/CHarfBuzz/upstream)
        .target(
            name: "CHarfBuzz",
            dependencies: ["CFreeType"],
            path: "Sources/CHarfBuzz",
            exclude: [
                "upstream/.github",
                "upstream/AUTHORS",
                "upstream/BUILD.md",
                "upstream/CMakeLists.txt",
                "upstream/CONFIG.md",
                "upstream/COPYING",
                "upstream/NEWS",
                "upstream/README.md",
                "upstream/README.mingw.md",
                "upstream/README.python.md",
                "upstream/RELEASING.md",
                "upstream/SECURITY.md",
                "upstream/TESTING.md",
                "upstream/THANKS",
                "upstream/docs",
                "upstream/harfbuzz.doap",
                "upstream/meson.build",
                "upstream/meson_options.txt",
                "upstream/perf",
                "upstream/replace-enum-strings.cmake",
                "upstream/subprojects",
                "upstream/test",
                "upstream/util",
                "upstream/xkcd.png",
            ],
            sources: ["upstream/src/harfbuzz.cc"],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("HAVE_FREETYPE"),
                .headerSearchPath("upstream/src"),
            ]
        ),

        // MARK: - Runtime
        // 平台层、布局引擎、文字渲染、节点树、recompose 运行时。
        // 依赖 Engine 的渲染抽象（RHIWGPU、PlatformShell、EngineKernel）。
        .target(
            name: "GuavaUIRuntime",
            dependencies: [
                .product(name: "yoga", package: "yoga"),
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
        // Google Sans Code variable font shipped with GuavaUI.
        .target(
            name: "GuavaUIBundledFonts",
            path: "Sources/Font",
            resources: [
                .copy("Inter.ttc"),
            ]
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
    ],
    cxxLanguageStandard: .cxx20
)
