// swift-tools-version: 6.4
import Foundation
import PackageDescription

let engineRoot = ProcessInfo.processInfo.environment["GUAVA_ENGINE_ROOT"] ?? "../.."

let package = Package(
    name: "GuavaApplication",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppContent", targets: ["AppContent"]),
        .executable(name: "DesktopApp", targets: ["DesktopApp"]),
    ],
    dependencies: [
        .package(path: "\(engineRoot)/GuavaUI"),
    ],
    targets: [
        .executableTarget(name: "DesktopApp", dependencies: [
            "AppContent", .product(name: "GuavaUI", package: "GuavaUI"),
        ]),
        .target(
            name: "AppContent",
            dependencies: [
                .product(name: "GuavaUI", package: "GuavaUI"),
            ],
            resources: [.copy("Assets")]
        ),
    ]
)
