import Foundation

enum Diagnostics {
    static func doctor(_ arguments: Arguments, root: URL) throws {
        print("Guava SDK: \(root.path)")
        print("Host: \(AppPlatform.host.rawValue); requested target: \(arguments.platform.rawValue)")
        try arguments.platform.requireAvailable()
        _ = try Shell.run([GuavaSDK.swift, "--version"])
        if arguments.platform == .android {
            let toolchain = try AndroidToolchain(root: root, arguments: arguments)
            for command in ["cmake", "ninja", "java", "javac", "jar", "keytool", "zip"] {
                print("\(command): \(try Shell.executable(command).path)")
            }
            for relative in ["platform-tools/adb", "platforms/android-36/android.jar", "build-tools/36.1.0/d8",
                             "build-tools/36.1.0/zipalign", "build-tools/36.1.0/apksigner"] {
                let path = toolchain.sdk.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: path.path) else { throw ToolError.invalid("Missing Android SDK component: \(path.path)") }
            }
            let sdks = try Shell.run([toolchain.swift, "sdk", "list"], capture: true)
            guard sdks.contains(AndroidToolchain.sdkID) else { throw ToolError.invalid("Install Swift SDK \(AndroidToolchain.sdkID)") }
            print("Android SDK: \(toolchain.sdk.path)\nNDK: \(toolchain.ndk.path)")
        } else {
            print("Desktop applications use the shared SDL3 / NativeRHI host. Prepare this checkout's native dependencies with bootstrap.py.")
        }
        print("Toolchain checks passed. Use guava build to validate native dependencies and application linking.")
    }

    static func devices(_ arguments: Arguments) throws {
        guard arguments.platform == .android else { throw ToolError.invalid("guava devices currently supports --android") }
        // Device enumeration does not need Swift's Android SDK, NDK or JDK.
        let sdk = AndroidToolchain.sdkDirectory(arguments)
        _ = try Shell.run([sdk.appendingPathComponent("platform-tools/adb").path, "devices", "-l"])
    }
}
