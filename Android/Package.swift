// swift-tools-version: 6.4
import PackageDescription

// Builds shared first-party sources without desktop-only native artifact bundles.
let package = Package(
    name: "GuavaAndroid",
    products: [
        .executable(name: "GuavaAndroidProbe", targets: ["GuavaAndroidProbe"]),
        .library(name: "GuavaAndroidApp", type: .dynamic, targets: ["GuavaAndroidApp"]),
    ],
    dependencies: [.package(path: "../GuavaUI/Portable")],
    targets: [
        .target(name: "CVulkanHeaders", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("vulkan")]),
        .target(name: "CDX12Bridge", publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-fexceptions"])]),
        .target(name: "NativeRHI", dependencies: ["CVulkanHeaders", "CDX12Bridge"], exclude: ["docs"]),
        .target(name: "GuavaUIRendering", dependencies: ["NativeRHI", .product(name: "GuavaUICore", package: "Portable")],
                resources: [.copy("Shaders")]),
        .target(name: "CAndroidHost", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("android"), .linkedLibrary("log")]),
        .target(name: "GuavaAndroidApp", dependencies: ["NativeRHI", "GuavaUIRendering", "CAndroidHost",
            .product(name: "GuavaUICore", package: "Portable")]),
        .executableTarget(name: "GuavaAndroidProbe", dependencies: ["NativeRHI", "GuavaUIRendering", .product(name: "GuavaUIComposeCore", package: "Portable")]),
    ]
)
