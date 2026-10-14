// swift-tools-version: 6.4
import PackageDescription

// The developer-facing CLI owns project workflows; platform backends are internal.
let package = Package(
    name: "GuavaTools",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "guava", targets: ["GuavaCLI"])],
    dependencies: [
        .package(path: "../../Engine/Logging"),.package(path: "../../Platforms/Android/Contract"), .package(path: "../../GuavaUI/Portable")],
    targets: [
        .executableTarget(name: "GuavaCLI", dependencies: [.product(name: "GuavaLogging", package: "Logging"),
            .product(name: "GuavaAndroidContract", package: "Contract"),
            .product(name: "GuavaUIDevToolsProtocol", package: "Portable"),
        ], resources: [.copy("Templates")]),
        .testTarget(name: "GuavaCLITests", dependencies: ["GuavaCLI"]),
    ]
)
