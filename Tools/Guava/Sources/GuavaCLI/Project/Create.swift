import Foundation

enum CreateApplication {
    static func run(_ arguments: Arguments, root: URL) throws {
        let destination = arguments.directory
        let slug = destination.lastPathComponent.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let identifier = slug.first?.isLetter == true ? slug : "app" + slug
        let identity = ApplicationIdentity(id: arguments.value(.id) ?? "com.example.\(identifier)",
                                           name: arguments.value(.name) ?? destination.lastPathComponent)
        let configuration = ProjectConfiguration(application: identity,
            toolchain: .init(enginePath: Files.relative(root, to: destination)))
        try configuration.validate()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let contents = try? Files.children(destination), contents.isEmpty else {
                throw ToolError.invalid("Refusing to overwrite nonempty destination: \(destination.path)")
            }
        }
        let templates = Bundle.module.resourceURL!.appendingPathComponent("Templates/UI")
        for source in try Files.files(templates) {
            var relative = Files.relative(source, to: templates)
            if relative.hasSuffix(".in") { relative.removeLast(3) }
            let text = try String(contentsOf: source, encoding: .utf8)
            try Files.text(text, to: destination.appendingPathComponent(relative))
        }
        try Files.json(configuration, to: destination.appendingPathComponent("guava.json"))
        print("Created cross-platform Guava application: \(destination.path)")
        print("Edit Sources/AppContent/App.swift, then: guava run \(destination.path)")
    }
}
