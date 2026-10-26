internal import ToolSupport
internal import Foundation

enum GameplayPackage {
    private struct Index: Decodable {
        struct Entry: Decodable { let source: String; let identifier: String }
        let entries: [Entry]
    }

    static func create(project: URL, destination: URL, root: URL) throws -> Int {
        try Fs.reset(destination)
        let indexURL = project.appendingPathComponent(".cove/static-scripts.json")
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
            guard file.path.hasPrefix(project.standardizedFileURL.path + "/") else { throw ToolError.message("Script source escapes exported project: \(entry.source)") }
            try Fs.copy(file, to: source.appendingPathComponent("GameScript.swift"))
            try Fs.write("""
                import ScriptRuntime
                public func registerProjectScript(into runtime: ScriptRuntime) {
                    runtime.register(behavior: GameScript.self, named: \(literal(entry.identifier)))
                }

                """, to: source.appendingPathComponent("Registration.swift"))
            targets.append(".target(name: \"\(module)\", dependencies: [\(dependencies)])")
            imports.append("import \(module)")
            registrations.append("        \(module).registerProjectScript(into: runtime)")
        }
        let registry = "import ScriptRuntime\n" + imports.joined(separator: "\n") + "\npublic enum ProjectGameplay {\n"
            + "    public static func register(into runtime: ScriptRuntime) -> Int {\n" + registrations.joined(separator: "\n")
            + "\n        return \(entries.count)\n    }\n}\n"
        try Fs.write(registry, to: destination.appendingPathComponent("Sources/CoveAndroidGameplay/Registry.swift"))
        let aggregate = [".product(name: \"ScriptRuntime\", package: \"Engine\")"] + entries.indices.map { "\"ProjectScript\($0)\"" }
        targets.append(".target(name: \"CoveAndroidGameplay\", dependencies: [\(aggregate.joined(separator: ", "))])")
        try Fs.write("""
            // swift-tools-version: 6.4
            import PackageDescription
            let package = Package(
                name: "CoveAndroidGameplay",
                platforms: [.macOS(.v26), .iOS(.v26)],
                products: [.library(name: "CoveAndroidGameplay", targets: ["CoveAndroidGameplay"])],
                dependencies: [.package(path: \(literal(root.appendingPathComponent("Engine").path)))],
                targets: [\(targets.joined(separator: ",\n        "))]
            )

            """, to: destination.appendingPathComponent("Package.swift"))
        return entries.count
    }
    private static func literal(_ value: String) -> String {
        // Swift accepts JSON's usual escapes but uses \u{...} for control scalars.
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 0...31, 127: result += "\\u{\(String(scalar.value, radix: 16))}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
