import Foundation

/// Testing needs a package, not application identity or native launch targets.
/// An authored guava.json still owns SDK selection and the app's isolated cache.
struct PackageTests {
    let command: [String]
    /// Desktop helper builds, so tests that launch a helper never run a stale one.
    let helpers: [[String]]
    let environment: [String: String]

    init(_ arguments: Arguments) throws {
        let directory = arguments.directory
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
            throw ToolError.invalid("\(directory.path) must contain Package.swift to run guava test")
        }
        let project = FileManager.default.fileExists(atPath: directory.appendingPathComponent("guava.json").path)
            ? try AppProject(at: directory) : nil
        let root = try GuavaSDK.locate(arguments, project: project)
        let scratchPath = project?.buildDirectory.appendingPathComponent("swift")
        var command = SwiftPackage.command(directory: directory, configuration: arguments.configuration, verb: "test",
            scratchPath: scratchPath)
        if let filter = arguments.value(.filter) { command += ["--filter", filter] }
        if arguments.flags.contains(.noParallel) { command.append("--no-parallel") }
        let build = SwiftPackage.command(directory: directory, configuration: arguments.configuration, scratchPath: scratchPath)
        helpers = (project?.configuration.targets.desktopHelpers ?? []).map { build + ["--product", $0] }
        self.command = command; environment = SwiftPackage.environment(root: root)
    }

    func run() throws {
        for helper in helpers { try Shell.run(helper, environment: environment) }
        try Shell.run(command, environment: environment)
    }
}
