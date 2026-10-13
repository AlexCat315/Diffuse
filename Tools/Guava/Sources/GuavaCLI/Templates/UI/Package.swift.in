// swift-tools-version: 6.4
import Foundation
import PackageDescription

// SwiftPM and the Guava CLI read the same SDK location from guava.json.
let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("guava.json"))) as! [String: Any]
let toolchain = document["toolchain"] as! [String: String]
let engineRoot = ProcessInfo.processInfo.environment["GUAVA_ENGINE_ROOT"]
    ?? URL(fileURLWithPath: toolchain["enginePath"]!, relativeTo: directory).standardizedFileURL.path

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
        .target(name: "AppContent", dependencies: [
            .product(name: "GuavaUI", package: "GuavaUI"),
        ], resources: [.copy("Assets")]),
        .testTarget(name: "AppContentTests", dependencies: ["AppContent"]),
    ]
)
