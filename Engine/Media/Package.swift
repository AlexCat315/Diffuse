// swift-tools-version: 6.1
import Foundation
import PackageDescription

let artifacts = ProcessInfo.processInfo.environment["GUAVA_MEDIA_ARTIFACT_ROOT"] ?? "vendor"
let package = Package(
    name: "GuavaMedia",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "MediaRuntime", targets: ["MediaRuntime"])],
    targets: [
        .binaryTarget(name: "FFmpeg", path: "\(artifacts)/FFmpeg.artifactbundle"),
        .target(name: "CFFmpegBridge", dependencies: ["FFmpeg"], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux, .android])),
                    .linkedLibrary("pthread", .when(platforms: [.linux])),
                    .linkedLibrary("bcrypt", .when(platforms: [.windows]))]),
        .target(name: "MediaRuntime", dependencies: ["CFFmpegBridge"]),
        .testTarget(name: "MediaRuntimeTests", dependencies: ["MediaRuntime"], resources: [.copy("Fixtures")]),
    ])
