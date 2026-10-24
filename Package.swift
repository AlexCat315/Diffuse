// swift-tools-version: 6.4
import PackageDescription

// Workspace convenience launcher. Editor/Package.swift owns the editor graph.
let package = Package(
    name: "GuavaStudioWorkspace",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GuavaStudio", targets: ["WorkspaceLauncher"])],
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
