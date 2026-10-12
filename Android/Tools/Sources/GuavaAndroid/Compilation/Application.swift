import Foundation

enum BuildApplication {
    static func run(_ arguments: Arguments, root: URL) throws {
        let options = try BuildOptions(arguments)
        let project = arguments.url("app")
        if project != nil, arguments.value("demo") != nil || arguments.value("component") != nil {
            throw ToolError.invalid("--app cannot be combined with --demo or --component")
        }
        let demo = arguments.value("demo") ?? "gallery"
        guard ["gallery", "counter"].contains(demo) else { throw ToolError.invalid("--demo must be gallery or counter") }
        var identity: ApplicationIdentity
        if let project { identity = try ApplicationIdentity.load(project) }
        else { identity = ApplicationIdentity(applicationID: "com.guava.probe", name: "GuavaUI " + demo.capitalized) }
        if let id = arguments.value("application-id") { identity.applicationID = id }
        if let name = arguments.value("name") { identity.name = name }
        try identity.validate()
        let toolchain = try AndroidToolchain(root: root, arguments: arguments)
        let output = try options.output(arguments, default: project?.appendingPathComponent("build/Application.apk") ?? toolchain.cache.appendingPathComponent("GuavaAndroidProbe.apk"))
        let scratch = project.map { toolchain.cache.appendingPathComponent("ui-apps/\(cacheKey($0))/swift") }
        let products = try toolchain.compile(product: "GuavaAndroidApp", configuration: options.configuration, content: project, scratch: scratch)
        let launch = SceneLaunch(mode: project == nil ? demo : "application", component: arguments.value("component") ?? "introduction")
        try APKPackage(toolchain: toolchain, identity: identity, configuration: options.configuration, signing: options.signing)
            .build(products: products, launch: launch, output: output)
        let report = BuildReport(application: identity, source: project?.path ?? demo, apk: output.path,
                                 configuration: options.configuration, signing: options.signing == nil ? "development" : "custom")
        try Files.json(report, to: output.deletingPathExtension().appendingPathExtension("json"))
        if options.install { try AndroidDevice.install(output, toolchain: toolchain, serial: options.serial, identity: identity) }
    }

    private static func cacheKey(_ project: URL) -> String {
        // Stable cache namespace without adding a cryptography package to host tooling.
        let hash = project.standardizedFileURL.path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}
