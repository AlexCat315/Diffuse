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
        let command = SwiftPackage.command(directory: package, configuration: arguments.configuration,
            scratchPath: project.buildDirectory.appendingPathComponent("swift"))
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

    static func command(directory: URL, configuration: BuildConfiguration, verb: String = "build", scratchPath: URL? = nil) -> [String] {
        var command = [GuavaSDK.swift, verb, "--package-path", directory.path,
                       "--configuration", configuration.swiftConfiguration, "--jobs", "4"] + configuration.swiftFlags
        if let scratchPath { command += ["--scratch-path", scratchPath.path] }
        return command
    }
}
