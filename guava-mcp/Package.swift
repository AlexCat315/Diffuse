// swift-tools-version: 5.9
// guava-mcp 0.0.1
import PackageDescription

let package = Package(
    name: "guava-mcp",
    targets: [
        .executableTarget(
            name: "GuavaMCP",
            path: "Sources/GuavaMCP"
        ),
    ]
)
