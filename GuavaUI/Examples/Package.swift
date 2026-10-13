// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GuavaUIExamples",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GalleryContent", targets: ["GalleryContent"]),
        .executable(name: "GuavaUIDemo", targets: ["GuavaUIDemo"]),
        .executable(name: "PetDemo", targets: ["PetDemo"]),
    ],
    dependencies: [.package(path: ".."), .package(path: "../../examples/Counter")],
    targets: [
        .target(name: "GalleryContent", dependencies: [
            .product(name: "CounterExample", package: "Counter"),
            .product(name: "GuavaUI", package: "GuavaUI"),
            .product(name: "GuavaUIWorkspace", package: "GuavaUI"),
        ], resources: [.process("Resources")]),
        .executableTarget(name: "GuavaUIDemo", dependencies: [
            "GalleryContent",
            .product(name: "GuavaUI", package: "GuavaUI"),
            .product(name: "CounterExample", package: "Counter"),
        ]),
        .executableTarget(name: "PetDemo", dependencies: [
            .product(name: "GuavaUI", package: "GuavaUI"),
        ], resources: [.process("Resources")]),
        .testTarget(name: "GalleryContentTests", dependencies: ["GalleryContent"]),
    ]
)
