// swift-tools-version: 6.4
// cove-mcp 0.0.9
import PackageDescription

let package = Package(
    name: "cove-mcp",
    platforms: [.macOS(.v26), .iOS(.v26)],
    dependencies: [
        .package(path: "../Engine"),
    ],
    targets: [
        .executableTarget(
            name: "CoveMCP",
            dependencies: [
                .product(name: "AIRuntime", package: "engine"),
                .product(name: "IntentRuntime", package: "engine"),
            ],
            path: "Sources/CoveMCP"
        ),
    ]
)
