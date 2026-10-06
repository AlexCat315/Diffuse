// swift-tools-version: 6.1
import PackageDescription
import Foundation

// Browser builds stage WASI artifacts separately from the desktop libraries.
let artifacts = ProcessInfo.processInfo.environment["GUAVA_TEXT_ARTIFACT_ROOT"] ?? "../vendor"
let package = Package(
    name: "GuavaUIText",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GuavaUIText", targets: ["GuavaUIText"]),
        .library(name: "CFreeType", targets: ["CFreeType"]),
        .library(name: "CHarfBuzz", targets: ["CHarfBuzz"]),
    ],
    dependencies: [.package(path: "../Portable")],
    targets: [
        .binaryTarget(name: "CFreeType", path: "\(artifacts)/CFreeType.artifactbundle"),
        .binaryTarget(name: "CHarfBuzz", path: "\(artifacts)/CHarfBuzz.artifactbundle"),
        .target(name: "GuavaUIText", dependencies: [
            "CFreeType", "CHarfBuzz", .product(name: "GuavaUICore", package: "Portable"),
        ]),
        .testTarget(name: "GuavaUITextTests", dependencies: ["GuavaUIText"]),
    ]
)
