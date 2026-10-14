// swift-tools-version: 6.1
import PackageDescription

// Portable example content, deliberately outside the production UI package.
let package = Package(
    name: "CounterExample",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "CounterExample", targets: ["CounterExample"])],
    dependencies: [.package(path: "../../GuavaUI/Portable")],
    targets: [
        .target(name: "CounterExample", dependencies: [
            .product(name: "GuavaUIComposeCore", package: "Portable"),
        ]),
        .testTarget(name: "CounterExampleTests", dependencies: [
            "CounterExample",
            .product(name: "GuavaUIDevToolsScene", package: "Portable"),
            .product(name: "GuavaUIDevToolsProtocol", package: "Portable"),
        ]),
    ]
)
