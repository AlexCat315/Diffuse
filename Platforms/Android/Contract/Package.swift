// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GuavaAndroidContract",
    products: [.library(name: "GuavaAndroidContract", targets: ["GuavaAndroidContract"])],
    targets: [
        .target(name: "GuavaAndroidContract"),
        .testTarget(name: "GuavaAndroidContractTests", dependencies: ["GuavaAndroidContract"]),
    ]
)
