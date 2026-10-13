import Foundation

enum Diagnostics {
    static func doctor(_ arguments: Arguments, root: URL) throws {
        try ToolchainSetup.report(arguments, root: root)
        print("Toolchain checks passed. guava setup prepares shared native archives; guava build validates application linking.")
    }

    static func devices(_ arguments: Arguments) throws {
        guard arguments.platform == .android else { throw ToolError.invalid("guava devices currently supports --android") }
        // Device enumeration does not need Swift's Android SDK, NDK or JDK.
        let sdk = AndroidToolchain.sdkDirectory(arguments)
        _ = try Shell.run([sdk.appendingPathComponent("platform-tools/adb").path, "devices", "-l"])
    }
}
