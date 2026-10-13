import Foundation

enum CreateApplication {
    static func run(_ arguments: Arguments, root: URL) throws {
        let destination = URL(fileURLWithPath: try arguments.required("directory")).standardizedFileURL
        let identity = ApplicationIdentity(applicationID: try arguments.required("application-id"),
                                           name: arguments.value("name") ?? "GuavaUI Application")
        try identity.validate()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let contents = try? Files.children(destination), contents.isEmpty else {
                throw ToolError.invalid("Refusing to overwrite nonempty destination: \(destination.path)")
            }
        }
        let templates = Bundle.module.resourceURL!.appendingPathComponent("Templates/UI")
        let enginePath = Files.relative(root, to: destination)
        for source in try Files.files(templates) {
            var relative = Files.relative(source, to: templates)
            if relative.hasSuffix(".in") { relative.removeLast(3) }
            let text = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(of: "{{ENGINE_ROOT}}", with: Files.swiftLiteral(enginePath))
                .replacingOccurrences(of: "{{APP_NAME}}", with: identity.name)
            try Files.text(text, to: destination.appendingPathComponent(relative))
        }
        try Files.json(identity, to: destination.appendingPathComponent("guava-android.json"))
        print("Created GuavaUI application: \(destination.path)")
        print("Edit Sources/AppContent/App.swift, then build with GuavaAndroid build --app \(destination.path)")
    }
}
