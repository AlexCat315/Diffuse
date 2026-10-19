import Foundation

/// Testing needs a package, not application identity or native launch targets.
/// An authored guava.json still owns SDK selection and the app's isolated cache.
struct PackageTests {
    let command: [String]
    let environment: [String: String]

    init(_ arguments: Arguments) throws {
        let directory = arguments.directory
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) else {
            throw ToolError.invalid("\(directory.path) must contain Package.swift to run guava test")
        }
        let project = FileManager.default.fileExists(atPath: directory.appendingPathComponent("guava.json").path)
            ? try AppProject(at: directory) : nil
        let root = try GuavaSDK.locate(arguments, project: project)
        var command = SwiftPackage.command(directory: directory, configuration: arguments.configuration, verb: "test",
            scratchPath: project?.buildDirectory.appendingPathComponent("swift"))
        if let filter = arguments.value(.filter) { command += ["--filter", filter] }
        if arguments.flags.contains(.noParallel) { command.append("--no-parallel") }
        self.command = command; environment = SwiftPackage.environment(root: root)
    }

    func run() throws { try Shell.run(command, environment: environment) }
}
