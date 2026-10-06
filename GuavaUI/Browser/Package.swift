// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GuavaUIBrowser",
    dependencies: [.package(path: "../Portable")],
    targets: [
        .executableTarget(name: "GuavaUIBrowserPrototype", dependencies: [
            .product(name: "GuavaUICore", package: "Portable"),
            .product(name: "GuavaUIDevToolsProtocol", package: "Portable"),
        ]),
    ]
)
