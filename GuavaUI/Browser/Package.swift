// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GuavaUIBrowser",
    dependencies: [.package(path: "../Portable"), .package(path: "../Text")],
    targets: [
        .executableTarget(name: "GuavaUIBrowserPrototype", dependencies: [
            .product(name: "GuavaUIText", package: "Text"),
            .product(name: "GuavaUISharedDemo", package: "Portable"),
            .product(name: "GuavaUICore", package: "Portable"),
            .product(name: "GuavaUIComposeCore", package: "Portable"),
            .product(name: "GuavaUIDevToolsScene", package: "Portable"),
            .product(name: "GuavaUIDevToolsProtocol", package: "Portable"),
        ]),
    ]
)
