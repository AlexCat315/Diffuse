import Foundation

enum CreateApplication {
    static func run(_ arguments: Arguments, root: URL) throws {
        let destination = arguments.directory
        let slug = destination.lastPathComponent.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let identifier = slug.first?.isLetter == true ? slug : "app" + slug
        let identity = ApplicationIdentity(id: arguments.value(.id) ?? "com.example.\(identifier)",
                                           name: arguments.value(.name) ?? destination.lastPathComponent)
        var configuration = ProjectConfiguration(application: identity,
            toolchain: .init(enginePath: Files.relative(root, to: destination)))
        if let platforms = arguments.value(.platforms) {
            configuration.targets.platforms = try platforms.split(separator: ",").map {
                guard let platform = AppPlatform(rawValue: String($0)) else { throw ToolError.invalid("Unknown platform: \($0)") }
                guard [.mac, .win, .linux, .android].contains(platform) else { throw ToolError.invalid("Platform template not implemented: \($0)") }
                return platform
            }
        }
        try configuration.validate()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let contents = try? Files.children(destination), contents.isEmpty else {
                throw ToolError.invalid("Refusing to overwrite nonempty destination: \(destination.path)")
            }
        }
        let templates = Bundle.module.resourceURL!.appendingPathComponent("Templates/UI")
        for source in try Files.files(templates) {
            var relative = Files.relative(source, to: templates)
            if relative.hasPrefix("Platforms/") {
                let name = relative.split(separator: "/")[1]
                if !configuration.targets.platforms.contains(where: { $0.directoryName == name }) { continue }
            }
            if relative.hasSuffix(".in") { relative.removeLast(3) }
            try Files.copy(source, to: destination.appendingPathComponent(relative))
        }
        try Files.json(configuration, to: destination.appendingPathComponent("guava.json"))
        print("Created cross-platform Guava application: \(destination.path)")
        print("Edit Sources/AppContent/App.swift, then: guava run \(destination.path)")
    }
}
