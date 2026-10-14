// swift-tools-version: 6.4
import PackageDescription

let package = Package(name: "GuavaLogging", platforms: [.macOS(.v13)], products: [
    .library(name: "GuavaLogging", targets: ["GuavaLogging"]),
    .library(name: "GuavaLogCore", targets: ["GuavaLogCore"]),
    .library(name: "CGuavaLog", targets: ["CGuavaLog"]),
], dependencies: [.package(url: "https://github.com/apple/swift-log.git", from: "1.15.1")], targets: [
    .target(name: "CGuavaLog", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("log", .when(platforms: [.android]))]),
    .target(name: "GuavaLogCore", dependencies: [.product(name: "Logging", package: "swift-log")]),
    .target(name: "GuavaLogging", dependencies: ["CGuavaLog", "GuavaLogCore"]),
    .testTarget(name: "GuavaLoggingTests", dependencies: ["GuavaLogging", "CGuavaLog"]),
])
