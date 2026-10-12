import Foundation

enum GameplayPackage {
    private struct Index: Decodable {
        struct Entry: Decodable { let source: String; let identifier: String }
        let entries: [Entry]
    }

    static func create(project: URL, destination: URL, root: URL) throws -> Int {
        try Files.reset(destination)
        let indexURL = project.appendingPathComponent(".guava/static-scripts.json")
        let entries: [Index.Entry]
        if FileManager.default.fileExists(atPath: indexURL.path) {
            entries = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)).entries
        } else { entries = [] }
        let products = ["EngineKernel", "SceneRuntime", "ScriptRuntime", "SIMDCompat"]
        let dependencies = products.map { ".product(name: \"\($0)\", package: \"Engine\")" }.joined(separator: ", ")
        var targets: [String] = [], imports: [String] = [], registrations: [String] = []
        for (number, entry) in entries.enumerated() {
            let module = "ProjectScript\(number)"
            let source = destination.appendingPathComponent("Sources/\(module)")
            let file = project.appendingPathComponent(entry.source).standardizedFileURL
            guard file.path.hasPrefix(project.standardizedFileURL.path + "/") else { throw ToolError.invalid("Script source escapes exported project: \(entry.source)") }
            try Files.copy(file, to: source.appendingPathComponent("GameScript.swift"))
            try Files.text("""
                import ScriptRuntime
                public func registerProjectScript(into runtime: ScriptRuntime) {
                    runtime.register(behavior: GameScript.self, named: \(Files.swiftLiteral(entry.identifier)))
                }

                """, to: source.appendingPathComponent("Registration.swift"))
            targets.append(".target(name: \"\(module)\", dependencies: [\(dependencies)])")
            imports.append("import \(module)")
            registrations.append("        \(module).registerProjectScript(into: runtime)")
        }
        let registry = "import ScriptRuntime\n" + imports.joined(separator: "\n") + "\npublic enum ProjectGameplay {\n"
            + "    public static func register(into runtime: ScriptRuntime) -> Int {\n" + registrations.joined(separator: "\n")
            + "\n        return \(entries.count)\n    }\n}\n"
        try Files.text(registry, to: destination.appendingPathComponent("Sources/GuavaAndroidGameplay/Registry.swift"))
        let aggregate = [".product(name: \"ScriptRuntime\", package: \"Engine\")"] + entries.indices.map { "\"ProjectScript\($0)\"" }
        targets.append(".target(name: \"GuavaAndroidGameplay\", dependencies: [\(aggregate.joined(separator: ", "))])")
        try Files.text("""
            // swift-tools-version: 6.4
            import PackageDescription
            let package = Package(
                name: "GuavaAndroidGameplay",
                products: [.library(name: "GuavaAndroidGameplay", targets: ["GuavaAndroidGameplay"])],
                dependencies: [.package(path: \(Files.swiftLiteral(root.appendingPathComponent("Engine").path)))],
                targets: [\(targets.joined(separator: ",\n        "))]
            )

            """, to: destination.appendingPathComponent("Package.swift"))
        return entries.count
    }
}
