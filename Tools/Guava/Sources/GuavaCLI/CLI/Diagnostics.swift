import Foundation

enum Diagnostics {
    static func doctor(_ arguments: Arguments, root: URL) throws {
        try ToolchainSetup.report(arguments, root: root)
        print("Toolchain checks passed. guava setup prepares shared native archives; guava build validates application linking.")
    }

    static func devices(_ arguments: Arguments) throws {
        if arguments.platform == .ios {
            try arguments.platform.requireAvailable()
            try Shell.run(["xcrun", "simctl", "list", "devices", "available"])
            try Shell.run(["xcrun", "devicectl", "list", "devices"])
            return
        }
        guard arguments.platform == .android else { throw ToolError.invalid("Use guava devices --android or --ios") }
        // Device enumeration does not need Swift's Android SDK, NDK or JDK.
        let sdk = AndroidToolchain.sdkDirectory(arguments)
        _ = try Shell.run([sdk.appendingPathComponent("platform-tools/adb").path, "devices", "-l"])
    }
}
