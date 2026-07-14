// swift-tools-version: 5.9
// guava-mcp 0.0.1
import PackageDescription

let package = Package(
    name: "guava-mcp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .executableTarget(
            name: "GuavaMCP",
            dependencies: [
                .product(name: "AIRuntime", package: "engine"),
                .product(name: "IntentRuntime", package: "engine"),
            ],
            path: "Sources/GuavaMCP"
        ),
    ]
)
