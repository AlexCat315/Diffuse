// swift-tools-version: 6.4
import Foundation
import PackageDescription

let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("guava.json"))) as! [String: Any]
let toolchain = document["toolchain"] as! [String: String]
let sdkVersion = Version(toolchain["sdkVersion"]!)!
let sdk: Package.Dependency = ProcessInfo.processInfo.environment["GUAVA_SDK_ROOT"].map { .package(name: "GuavaUI", path: $0) }
    ?? .package(url: "https://github.com/AlexCat315/GuavaUI.git", exact: sdkVersion)

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
        sdk,
    ],
    targets: [
        .target(name: "AppContent", dependencies: [
            .product(name: "GuavaUI", package: "GuavaUI"),
        ] + (hasNativeSources ? [.target(name: "PlatformSupport", condition: .when(platforms: [.macOS, .windows, .linux]))] : []), resources: [.copy("Assets")]),
        .testTarget(name: "AppContentTests", dependencies: ["AppContent"]),
    ] + platformTargets
)
