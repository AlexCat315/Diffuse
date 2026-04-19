// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "mouse-engine",
    products: [
        .library(name: "MouseEngineCore", targets: ["MouseEngineCore"]),
        .library(name: "MouseEngineRPC", targets: ["MouseEngineRPC"]),
    ],
    dependencies: [
        .package(path: "../../../../mouse-rhi")
    ],
    targets: [
        .target(
            name: "CMouseEngine",
            path: "Sources/CMouseEngine",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MouseEngineCore",
            dependencies: [
                .product(name: "MouseRHI", package: "mouse-rhi")
            ],
            path: "Sources/MouseEngineCore"
        ),
        .target(
            name: "MouseEngineRPC",
            dependencies: ["MouseEngineCore"],
            path: "Sources/MouseEngineRPC"
        ),
        .testTarget(
            name: "MouseEngineTests",
            dependencies: ["MouseEngineCore", "MouseEngineRPC"],
            path: "Tests/MouseEngineTests"
        ),
    ]
)
