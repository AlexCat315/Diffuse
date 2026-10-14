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
    .package(path: "../../GuavaUI/Examples"), .package(path: "../../examples/Counter"),
] : []
let showcaseTargets: [Target.Dependency] = showcase ? [
    .product(name: "GalleryContent", package: "Examples"),
    .product(name: "CounterExample", package: "Counter"),
] : []
let applicationSettings: [SwiftSetting] = (gameplayPath == nil ? [] : [.define("GUAVA_ANDROID_GAME")])
    + (contentPath == nil ? [] : [.define("GUAVA_ANDROID_UI")])
    + (showcase ? [.define("GUAVA_ANDROID_SHOWCASE")] : [])

let package = Package(
    name: "GuavaAndroid",
    products: [
        .executable(name: "GuavaAndroidProbe", targets: ["GuavaAndroidProbe"]),
        .library(name: "GuavaAndroidApp", type: .dynamic, targets: ["GuavaAndroidApp"]),
    ],
    dependencies: [
        .package(path: "../../Engine/Logging"),
        .package(path: "Contract"), .package(path: "../../Engine"),
        .package(path: "../../GuavaUI"), .package(path: "../../GuavaUI/Portable"),
    ] + contentPackages + gamePackages + showcasePackages,
    targets: [
        .target(name: "CAndroidHost", dependencies: [.product(name: "CGuavaLog", package: "Logging")], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("android"), .linkedLibrary("log")]),
        .target(name: "GuavaAndroidApp", dependencies: [.product(name: "GuavaLogging", package: "Logging"),
            .product(name: "GuavaAndroidContract", package: "Contract"),
            .product(name: "NativeRHI", package: "Engine"),
            .product(name: "RenderBackend", package: "Engine"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"),
            .product(name: "GuavaUIAndroid", package: "GuavaUI"),
                .product(name: "GuavaUIDevTools", package: "GuavaUI"), "CAndroidHost",
        ] + contentTargets + gameTargets + showcaseTargets,
            swiftSettings: applicationSettings,
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z"),
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "defs"])]),
        .executableTarget(name: "GuavaAndroidProbe", dependencies: [.product(name: "GuavaLogging", package: "Logging"),
            .product(name: "NativeRHI", package: "Engine"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"),
            .product(name: "GuavaUIComposeCore", package: "Portable"),
        ], linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z")]),
    ]
)
