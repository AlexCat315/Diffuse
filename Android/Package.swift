// swift-tools-version: 6.4
import PackageDescription
import Foundation

let gameplayPath = ProcessInfo.processInfo.environment["GUAVA_ANDROID_GAME_PACKAGE"]
let gameplayPackages: [Package.Dependency] = gameplayPath.map { [.package(path: $0)] } ?? []
let gameplayTargets: [Target.Dependency] = gameplayPath == nil ? [] : [.product(name: "GuavaAndroidGameplay", package: "GuavaAndroidGameplay")]
let contentPath = ProcessInfo.processInfo.environment["GUAVA_ANDROID_UI_PACKAGE"]
let contentPackages: [Package.Dependency] = contentPath.map { [.package(path: $0)] } ?? []
let contentTargets: [Target.Dependency] = contentPath.map {
    [.product(name: "GuavaAndroidContent", package: URL(fileURLWithPath: $0).lastPathComponent)]
} ?? []
let applicationSettings: [SwiftSetting] = (gameplayPath == nil ? [] : [.define("GUAVA_ANDROID_GAME")])
    + (contentPath == nil ? [] : [.define("GUAVA_ANDROID_UI")])

// Uses the production Engine, GuavaUI and GameRuntime with Android native archives.
let package = Package(
    name: "GuavaAndroid",
    products: [
        .executable(name: "GuavaAndroidProbe", targets: ["GuavaAndroidProbe"]),
        .library(name: "GuavaAndroidApp", type: .dynamic, targets: ["GuavaAndroidApp"]),
    ],
    dependencies: [.package(path: "../Engine"), .package(path: "../GuavaUI"), .package(path: "../Editor"),
                   .package(path: "../GuavaUI/Portable"), .package(path: "../GuavaUI/Text")] + gameplayPackages + contentPackages,
    targets: [
        .target(name: "CAndroidHost", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("android"), .linkedLibrary("log")]),
        .target(name: "GuavaAndroidApp", dependencies: [.product(name: "NativeRHI", package: "Engine"),
            .product(name: "GameRuntime", package: "Editor"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"), .product(name: "GuavaUIGallery", package: "GuavaUI"), "CAndroidHost",
            .product(name: "GuavaUISharedDemo", package: "Portable"), .product(name: "GuavaUIText", package: "Text")] + gameplayTargets + contentTargets,
            swiftSettings: applicationSettings,
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z"),
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "defs"]) ]),
        .executableTarget(name: "GuavaAndroidProbe", dependencies: [.product(name: "NativeRHI", package: "Engine"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"), .product(name: "GuavaUIComposeCore", package: "Portable")],
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z")]),
    ]
)
