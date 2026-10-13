import Foundation

enum ApplicationTemplates {
    static var root: URL { Bundle.module.resourceURL!.appendingPathComponent("Templates/UI") }

    static func installAndroid(at project: URL, configuration: ProjectConfiguration) throws {
        let source = root.appendingPathComponent("Platforms/Android")
        try Files.copy(source, to: project.appendingPathComponent("Platforms/Android"))
        try Files.json(configuration, to: project.appendingPathComponent("guava.json"))
        try Files.text("// Generated packaging workspace\n", to: project.appendingPathComponent("Package.swift"))
    }
}
