// swift-tools-version: 6.4
import PackageDescription
import Foundation

let gameplayPath = ProcessInfo.processInfo.environment["GUAVA_ANDROID_GAME_PACKAGE"]
let gameplayPackages: [Package.Dependency] = gameplayPath.map { [.package(path: $0)] } ?? []
let gameplayTargets: [Target.Dependency] = gameplayPath == nil ? [] : [.product(name: "GuavaAndroidGameplay", package: "GuavaAndroidGameplay")]

// Uses the production Engine, GuavaUI and GameRuntime with Android native archives.
let package = Package(
    name: "GuavaAndroid",
    products: [
        .executable(name: "GuavaAndroidProbe", targets: ["GuavaAndroidProbe"]),
        .library(name: "GuavaAndroidApp", type: .dynamic, targets: ["GuavaAndroidApp"]),
    ],
    dependencies: [.package(path: "../Engine"), .package(path: "../GuavaUI"), .package(path: "../Editor"),
                   .package(path: "../GuavaUI/Portable"), .package(path: "../GuavaUI/Text")] + gameplayPackages,
    targets: [
        .target(name: "CAndroidHost", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("android"), .linkedLibrary("log")]),
        .target(name: "GuavaAndroidApp", dependencies: [.product(name: "NativeRHI", package: "Engine"),
            .product(name: "GameRuntime", package: "Editor"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"), .product(name: "GuavaUIGallery", package: "GuavaUI"), "CAndroidHost",
            .product(name: "GuavaUISharedDemo", package: "Portable"), .product(name: "GuavaUIText", package: "Text")] + gameplayTargets,
            swiftSettings: gameplayPath == nil ? [] : [.define("GUAVA_ANDROID_GAME")],
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z"),
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "defs"]) ]),
        .executableTarget(name: "GuavaAndroidProbe", dependencies: [.product(name: "NativeRHI", package: "Engine"),
            .product(name: "GuavaUIRuntime", package: "GuavaUI"), .product(name: "GuavaUIComposeCore", package: "Portable")],
            linkerSettings: [.linkedLibrary("ssl"), .linkedLibrary("crypto"), .linkedLibrary("z")]),
    ]
)
