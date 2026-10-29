// swift-tools-version: 6.4
// diffuse-mcp 0.1.0
import PackageDescription

let package = Package(
    name: "diffuse-mcp",
    platforms: [.macOS(.v26), .iOS(.v26)],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .executableTarget(
            name: "DiffuseMCP",
            dependencies: [
                .product(name: "AIRuntime", package: "engine"),
                .product(name: "IntentRuntime", package: "engine"),
            ],
            path: "Sources/DiffuseMCP"
        ),
    ]
)
