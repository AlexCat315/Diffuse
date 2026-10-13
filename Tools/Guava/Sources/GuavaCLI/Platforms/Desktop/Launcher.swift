import Foundation

/// Ordinary UI projects supply AppContent. A custom executable is an explicit opt-in.
struct DesktopLauncher {
    let project: AppProject
    let root: URL

    func prepare() throws -> URL {
        if project.configuration.targets.desktopExecutable != nil { return project.directory }
        let directory = project.buildDirectory.appendingPathComponent("desktop/launcher")
        let package = """
        // swift-tools-version: 6.4
        import PackageDescription
        let package = Package(name: "GuavaLauncher", platforms: [.macOS(.v13)],
            dependencies: [.package(name: "Content", path: \(Files.swiftLiteral(project.directory.path))),
                           .package(path: \(Files.swiftLiteral(root.appendingPathComponent("GuavaUI").path)))],
            targets: [.executableTarget(name: "Application", dependencies: [
                .product(name: "AppContent", package: "Content"),
                .product(name: "GuavaUI", package: "GuavaUI")])])
        """
        try Files.text(package, to: directory.appendingPathComponent("Package.swift"))
        try Files.text("import GuavaUI\nimport AppContent\ntry Application.run { makeApplicationContent() }\n",
                       to: directory.appendingPathComponent("Sources/Application/main.swift"))
        return directory
    }

}
