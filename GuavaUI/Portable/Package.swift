// swift-tools-version: 6.1
import PackageDescription

// Shared UI and DevTools build without SDL, GPU drivers or native font libraries.
// Browser targets depend only on the protocol, never on the socket transport.
let package = Package(
    name: "GuavaUIPortable",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GuavaUISharedDemo", targets: ["GuavaUISharedDemo"]),
        .library(name: "GuavaUIScene", targets: ["GuavaUIScene"]),
        .library(name: "GuavaUIComposeCore", targets: ["GuavaUIComposeCore"]),
        .library(name: "CYoga", targets: ["CYoga"]),
        .library(name: "GuavaUIDevToolsScene", targets: ["GuavaUIDevToolsScene"]),
        .library(name: "GuavaUICore", targets: ["GuavaUICore"]),
        .library(name: "GuavaUIDevToolsProtocol", targets: ["GuavaUIDevToolsProtocol"]),
        .library(name: "GuavaUIDevToolsServer", targets: ["GuavaUIDevToolsServer"]),
        .executable(name: "GuavaUIDevToolsProbe", targets: ["GuavaUIDevToolsProbe"]),
    ],
    dependencies: [
        .package(path: "../../Engine/PlatformCore"),
        .package(url: "https://github.com/facebook/yoga.git", from: "3.2.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    ],
    targets: [
        .target(name: "CYoga", dependencies: [.product(name: "yoga", package: "yoga")], publicHeadersPath: "include"),
        .target(name: "GuavaUIScene", dependencies: ["GuavaUICore", "CYoga", .product(name: "GuavaPlatformCore", package: "PlatformCore")]),
        .target(name: "GuavaUISharedDemo", dependencies: ["GuavaUIComposeCore"]),
        .target(name: "GuavaUIComposeCore", dependencies: ["GuavaUIScene"]),
        .target(name: "GuavaUIDevToolsScene", dependencies: ["GuavaUIScene", "GuavaUIDevToolsProtocol"]),
        .target(name: "GuavaUICore"),
        .testTarget(name: "GuavaUISceneTests", dependencies: ["GuavaUISharedDemo", "GuavaUIDevToolsScene", "GuavaUIDevToolsProtocol"]),
        .testTarget(name: "GuavaUICoreTests", dependencies: ["GuavaUICore"]),
        .target(name: "GuavaUIDevToolsProtocol", dependencies: [.product(name: "GuavaPlatformCore", package: "PlatformCore")]),
        .target(name: "GuavaUIDevToolsServer", dependencies: [
            "GuavaUIDevToolsProtocol",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "GuavaUIDevToolsProbe", dependencies: [
            "GuavaUIDevToolsServer", "GuavaUIDevToolsScene", "GuavaUIComposeCore",
        ]),
        .testTarget(name: "GuavaUIDevToolsServerTests", dependencies: [
            "GuavaUIDevToolsServer", "GuavaUIDevToolsProtocol",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
    ]
)
