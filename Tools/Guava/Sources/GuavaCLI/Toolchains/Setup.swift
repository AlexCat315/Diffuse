import Foundation

enum ToolchainSetup {
    static func report(_ arguments: Arguments, root: URL) throws {
        try arguments.platform.requireAvailable()
        print("Guava SDK: \(root.path)\nHost: \(AppPlatform.host.rawValue); target: \(arguments.platform.rawValue)")
        let checks = ToolchainRequirements.inspect(arguments, root: root)
        for check in checks { print("[\(check.ready ? "OK" : "MISSING")] \(check.name)") }
        let remedies = checks.filter { !$0.ready }.map(\.remedy)
        for remedy in Array(Set(remedies)).sorted() { print("\n\(remedy)") }
        guard remedies.isEmpty else { throw ToolError.invalid("Complete the target-specific steps above, then rerun guava setup.") }
    }

    static func run(_ arguments: Arguments, root: URL) throws {
        try report(arguments, root: root)
        if arguments.platform == .ios {
            try DeveloperTool.run(["ios-native"], root: root)
        } else if arguments.platform != .android {
            // SDK native archives are built once, shared by all application projects.
            try DeveloperTool.run(["native-bootstrap"], root: root)
        }
        print("Ready. guava create app MyApp; guava run MyApp --\(arguments.platform.rawValue)")
    }
}
