import GuavaAndroidContract
import Foundation

enum BuildAndroidApplication {
    static func prepare(_ arguments: Arguments, root: URL, project: AppProject) throws {
        try project.require(.android)
        let toolchain = try AndroidToolchain(root: root, arguments: arguments)
        let products = try toolchain.compile(product: "GuavaAndroidApp", configuration: arguments.configuration,
            content: project.directory, scratch: project.buildDirectory.appendingPathComponent("android/swift"))
        try APKPackage(toolchain: toolchain, identity: project.configuration.application, mode: arguments.configuration,
            signing: nil, application: project).stage(products: products, launch: SceneLaunch(mode: .application), application: project)
    }

    static func run(_ arguments: Arguments, root: URL, project: AppProject? = nil) throws {
        let options = try BuildOptions(arguments)
        let showcase = arguments.subject ?? "gallery"
        if project == nil, !["gallery", "counter"].contains(showcase) {
            throw ToolError.invalid("Showcase must be gallery or counter")
        }
        let identity = project?.configuration.application
            ?? ApplicationIdentity(id: "com.guava.probe", name: "GuavaUI " + showcase.capitalized)
        let toolchain = try AndroidToolchain(root: root, arguments: arguments)
        let directory = project?.buildDirectory.appendingPathComponent("android/\(options.configuration.rawValue)")
            ?? toolchain.cache
        let output = try options.output(arguments, default: directory.appendingPathComponent("Application.apk"))
        let products = try toolchain.compile(product: "GuavaAndroidApp", configuration: options.configuration,
            content: project?.directory, scratch: project?.buildDirectory.appendingPathComponent("android/swift"))
        let launch = SceneLaunch(mode: project == nil ? SceneLaunch.Mode(rawValue: showcase)! : .application,
                                component: arguments.value(.component) ?? "introduction")
        try APKPackage(toolchain: toolchain, identity: identity, mode: options.configuration, signing: options.signing, application: project)
            .build(products: products, launch: launch, output: output)
        let report = BuildReport(application: identity, source: project?.directory.path ?? showcase, apk: output.path,
                                 configuration: options.configuration.rawValue, signing: options.signing == nil ? "development" : "custom")
        try Files.json(report, to: output.deletingPathExtension().appendingPathExtension("json"))
        print("Built Android application: \(output.path)")
        if options.install {
            if let project { try AndroidRun.run(apk: output, project: project, toolchain: toolchain, arguments: arguments) }
            else { _ = try AndroidDevice.install(output, toolchain: toolchain, serial: options.serial, identity: identity) }
        }
    }
}
