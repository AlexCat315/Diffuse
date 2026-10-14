// swift-tools-version: 6.4
import Foundation
import PackageDescription

// SwiftPM and the Guava CLI read the same SDK location from guava.json.
let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("guava.json"))) as! [String: Any]
let toolchain = document["toolchain"] as! [String: String]
let engineRoot = ProcessInfo.processInfo.environment["GUAVA_ENGINE_ROOT"]
    ?? URL(fileURLWithPath: toolchain["enginePath"]!, relativeTo: directory).standardizedFileURL.path

#if os(macOS)
let nativeDirectory = "Platforms/macOS/Sources"
#elseif os(Windows)
let nativeDirectory = "Platforms/Windows/Sources"
#else
let nativeDirectory = "Platforms/Linux/Sources"
#endif
let hasNativeSources = FileManager.default.fileExists(atPath: directory.appendingPathComponent(nativeDirectory).path)
let platformTargets: [Target] = hasNativeSources ? [
    .target(name: "PlatformSupport", dependencies: [.product(name: "GuavaUI", package: "GuavaUI")], path: nativeDirectory)
] : []

let package = Package(
    name: "GuavaApplication",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AppContent", targets: ["AppContent"]),
    ],
    dependencies: [
        .package(path: "\(engineRoot)/GuavaUI"),
    ],
    targets: [
        .target(name: "AppContent", dependencies: [
            .product(name: "GuavaUI", package: "GuavaUI"),
        ] + (hasNativeSources ? [.target(name: "PlatformSupport", condition: .when(platforms: [.macOS, .windows, .linux]))] : []), resources: [.copy("Assets")]),
        .testTarget(name: "AppContentTests", dependencies: ["AppContent"]),
    ] + platformTargets
)
