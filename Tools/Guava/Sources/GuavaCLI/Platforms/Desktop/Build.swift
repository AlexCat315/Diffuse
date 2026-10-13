import Foundation

struct DesktopBuild {
    let project: AppProject
    let root: URL
    let arguments: Arguments

    func run() throws {
        let binaries = try compile()
        let artifact = try DesktopPackage(project: project, platform: arguments.platform)
            .assemble(binaries: binaries, configuration: arguments.configuration, output: arguments.url(.output))
        try NativeDesktopResources(project: project, platform: arguments.platform).sign(artifact, configuration: arguments.configuration)
        print("Built \(arguments.platform.rawValue) application: \(artifact.directory.path)")
        if arguments.operation == .run {
            try DesktopRun.run(artifact.executable, project: project, root: root, arguments: arguments)
        }
    }

    private func compile() throws -> URL {
        let package = try DesktopLauncher(project: project, root: root).prepare()
        let command = SwiftPackage.command(project: project, configuration: arguments.configuration, package: package)
        try Shell.run(command + ["--product", project.desktopProduct], environment: SwiftPackage.environment(root: root))
        return URL(fileURLWithPath: try Shell.run(command + ["--show-bin-path"], environment: SwiftPackage.environment(root: root), capture: true))
    }
}

enum SwiftPackage {
    static func environment(root: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GUAVA_ENGINE_ROOT"] = root.path
        return environment
    }

    static func command(project: AppProject, configuration: BuildConfiguration, verb: String = "build", package: URL? = nil) -> [String] {
        [GuavaSDK.swift, verb, "--package-path", (package ?? project.directory).path,
         "--scratch-path", project.buildDirectory.appendingPathComponent("swift").path,
         "--configuration", configuration.swiftConfiguration, "--jobs", "4"] + configuration.swiftFlags
    }

    static func test(project: AppProject, root: URL, arguments: Arguments) throws {
        var command = command(project: project, configuration: arguments.configuration, verb: "test")
        if let filter = arguments.value(.filter) { command += ["--filter", filter] }
        try Shell.run(command, environment: environment(root: root))
    }
}
