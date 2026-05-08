// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "guava-mcp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GuavaMCP",
            path: "Sources/GuavaMCP"
        ),
    ]
)
