// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "HelloUI",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../GuavaUI")],
    targets: [.executableTarget(name: "HelloUI", dependencies: [
        .product(name: "GuavaUI", package: "GuavaUI"),
    ])]
)
