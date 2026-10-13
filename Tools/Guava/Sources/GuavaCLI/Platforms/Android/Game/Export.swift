import GuavaAndroidContract
import Foundation

enum ExportGame {
    static func run(_ arguments: Arguments, root: URL) throws {
        let options = try BuildOptions(arguments)
        let project = arguments.directory
        let identity = ApplicationIdentity(id: try arguments.required(.id), name: arguments.value(.name) ?? project.lastPathComponent)
        try identity.validate()
        let toolchain = try AndroidToolchain(root: root, arguments: arguments)
        let output = try options.output(arguments, default: project.appendingPathComponent("build/\(project.lastPathComponent).apk"))
        let directory = toolchain.cache.appendingPathComponent("export-" + identity.id)
        let staged = directory.appendingPathComponent("Project")
        try Files.directory(directory)
        let editor = root.appendingPathComponent("Editor").path
        try Shell.run([toolchain.swift, "build", "--package-path", editor, "--product", "GuavaProjectExport"])
        let binaries = try Shell.run([toolchain.swift, "build", "--package-path", editor, "--show-bin-path"], capture: true)
        try Shell.run([URL(fileURLWithPath: binaries).appendingPathComponent("GuavaProjectExport").path,
                       "--project", project.path, "--output", staged.path, "--static-scripts", "--name", identity.name])
        let package = directory.appendingPathComponent("GuavaAndroidGameplay")
        let count = try GameplayPackage.create(project: staged, destination: package, root: root)
        let products = try toolchain.compile(product: "GuavaAndroidApp", configuration: options.configuration, gameplay: package)
        try APKPackage(toolchain: toolchain, identity: identity, mode: options.configuration, signing: options.signing)
            .build(products: products, launch: SceneLaunch(mode: .game, project: "GuavaProject"), output: output, project: staged)
        let report = BuildReport(application: identity, source: project.path, apk: output.path, configuration: options.configuration.rawValue,
                                 signing: options.signing == nil ? "development" : "custom", scripts: count)
        try Files.json(report, to: output.deletingPathExtension().appendingPathExtension("json"))
        try Files.copy(staged.appendingPathComponent("build.json"), to: output.deletingPathExtension().appendingPathExtension("project.json"))
    }
}
