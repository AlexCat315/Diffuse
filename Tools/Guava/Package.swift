// swift-tools-version: 6.4
import PackageDescription

// The developer-facing CLI owns project workflows; platform backends are internal.
let package = Package(
    name: "GuavaTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "guava", targets: ["GuavaCLI"])],
    dependencies: [.package(path: "../../Platforms/Android/Contract")],
    targets: [
        .executableTarget(name: "GuavaCLI", dependencies: [
            .product(name: "GuavaAndroidContract", package: "Contract"),
        ], resources: [.copy("Templates")]),
        .testTarget(name: "GuavaCLITests", dependencies: ["GuavaCLI"]),
    ]
)
