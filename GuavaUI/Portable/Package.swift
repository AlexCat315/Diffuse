// swift-tools-version: 6.1
import PackageDescription

// The wire protocol and server build without SDL, GPU drivers or font libraries.
// Browser targets depend only on the protocol, never on the socket transport.
let package = Package(
    name: "GuavaUIPortable",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GuavaUICore", targets: ["GuavaUICore"]),
        .library(name: "GuavaUIDevToolsProtocol", targets: ["GuavaUIDevToolsProtocol"]),
        .library(name: "GuavaUIDevToolsServer", targets: ["GuavaUIDevToolsServer"]),
        .executable(name: "GuavaUIDevToolsProbe", targets: ["GuavaUIDevToolsProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.103.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.1"),
    ],
    targets: [
        .target(name: "GuavaUICore"),
        .testTarget(name: "GuavaUICoreTests", dependencies: ["GuavaUICore"]),
        .target(name: "GuavaUIDevToolsProtocol"),
        .target(name: "GuavaUIDevToolsServer", dependencies: [
            "GuavaUIDevToolsProtocol",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "GuavaUIDevToolsProbe", dependencies: [
            "GuavaUIDevToolsServer", "GuavaUIDevToolsProtocol",
        ]),
        .testTarget(name: "GuavaUIDevToolsServerTests", dependencies: [
            "GuavaUIDevToolsServer", "GuavaUIDevToolsProtocol",
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
    ]
)
