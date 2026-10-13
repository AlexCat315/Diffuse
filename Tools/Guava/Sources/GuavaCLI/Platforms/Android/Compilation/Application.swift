import GuavaAndroidContract
import Foundation

enum BuildAndroidApplication {
    static func run(_ arguments: Arguments, root: URL, project: AppProject? = nil) throws {
        let options = try BuildOptions(arguments)
        let showcase = arguments.subject ?? "gallery"
        if project == nil, !["gallery", "counter"].contains(showcase) {
            throw ToolError.invalid("Showcase must be gallery or counter")
        }
        let identity = project?.configuration.application
            ?? ApplicationIdentity(id: "com.guava.probe", name: "GuavaUI " + showcase.capitalized)
        let toolchain = try AndroidToolchain(root: root, arguments: arguments)
        let directory = project?.buildDirectory.appendingPathComponent("android/\(options.configuration)")
            ?? toolchain.cache
        let output = try options.output(arguments, default: directory.appendingPathComponent("Application.apk"))
        let products = try toolchain.compile(product: "GuavaAndroidApp", configuration: options.configuration,
            content: project?.directory, scratch: project?.buildDirectory.appendingPathComponent("android/swift"))
        let launch = SceneLaunch(mode: project == nil ? SceneLaunch.Mode(rawValue: showcase)! : .application,
                                component: arguments.value(.component) ?? "introduction")
        try APKPackage(toolchain: toolchain, identity: identity, configuration: options.configuration, signing: options.signing)
            .build(products: products, launch: launch, output: output,
                   staging: project?.buildDirectory.appendingPathComponent("android/apk"))
        let report = BuildReport(application: identity, source: project?.directory.path ?? showcase, apk: output.path,
                                 configuration: options.configuration, signing: options.signing == nil ? "development" : "custom")
        try Files.json(report, to: output.deletingPathExtension().appendingPathExtension("json"))
        print("Built Android application: \(output.path)")
        if options.install { try AndroidDevice.install(output, toolchain: toolchain, serial: options.serial, identity: identity) }
    }
}
