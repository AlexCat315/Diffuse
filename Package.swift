// swift-tools-version: 6.1
import PackageDescription

// Workspace convenience launcher. Editor/Package.swift owns the editor graph.
let package = Package(
    name: "GuavaEngineWorkspace",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GuavaEditor", targets: ["WorkspaceLauncher"])],
    dependencies: [.package(path: "Editor")],
    targets: [
        .executableTarget(name: "WorkspaceLauncher", dependencies: [
            .product(name: "EditorUI", package: "Editor"),
        ], path: "Editor/Sources/EditorApp", linkerSettings: [
            .unsafeFlags(["-Xlinker", "-export_dynamic"], .when(platforms: [.macOS])),
            .unsafeFlags(["-Xlinker", "--export-dynamic"], .when(platforms: [.linux])),
        ]),
    ]
)
