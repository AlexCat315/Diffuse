// swift-tools-version: 6.4
import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let gameplayPath = environment["GUAVA_ANDROID_GAME_PACKAGE"]
let contentPath = environment["GUAVA_ANDROID_UI_PACKAGE"]
let showcase = gameplayPath == nil && contentPath == nil

let contentPackages: [Package.Dependency] = contentPath.map { [.package(path: $0)] } ?? []
let contentTargets: [Target.Dependency] = contentPath.map {
    [.product(name: "AppContent", package: URL(fileURLWithPath: $0).lastPathComponent)]
} ?? []
let gamePackages: [Package.Dependency] = gameplayPath.map {
    [.package(path: $0), .package(path: "../../Editor")]
} ?? []
let gameTargets: [Target.Dependency] = gameplayPath.map {
    [.product(name: "GuavaAndroidGameplay", package: URL(fileURLWithPath: $0).lastPathComponent),
     .product(name: "GameRuntime", package: "Editor")]
} ?? []
let showcasePackages: [Package.Dependency] = showcase ? [
    .package(path: "../../GuavaUI/Examples"),
] : []
let showcaseTargets: [Target.Dependency] = showcase ? [
    .product(name: "GalleryContent", package: "Examples"),
    .product(name: "CounterExample", package: "Examples"),
] : []
let applicationSettings: [SwiftSetting] = (gameplayPath == nil ? [] : [.define("GUAVA_ANDROID_GAME")])
    + (contentPath == nil ? [] : [.define("GUAVA_ANDROID_UI")])
    + (showcase ? [.define("GUAVA_ANDROID_SHOWCASE")] : [])

let package = Package(
    name: "GuavaAndroid",
    products: [
        .library(name: "GuavaAndroidApp", type: .dynamic, targets: ["GuavaAndroidApp"]),
    ],
    dependencies: [
        .package(path: "../../GuavaUI/Hosts/Android/Contract"), .package(path: "../../Engine"),
        .package(path: "../../GuavaUI"),
    ] + contentPackages + gamePackages + showcasePackages,
    targets: [
        .target(name: "CAndroidHost", dependencies: [.product(name: "CGuavaLog", package: "GuavaUI")], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("android"), .linkedLibrary("log")]),
        .target(name: "GuavaAndroidApp", dependencies: [.product(name: "GuavaLogging", package: "GuavaUI"),
            .product(name: "GuavaAndroidContract", package: "Contract"),
            .product(name: "NativeRHI", package: "GuavaUI"),
            .product(name: "RenderBackend", package: "Engine"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"),
            .product(name: "GuavaUIAndroid", package: "GuavaUI"),
                .product(name: "GuavaUIDevTools", package: "GuavaUI"), "CAndroidHost",
        ] + contentTargets + gameTargets + showcaseTargets,
            swiftSettings: applicationSettings,
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z"),
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "defs"])]),
    ]
)
