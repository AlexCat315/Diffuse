import Foundation

enum AndroidRequirements {
    static func inspect(_ arguments: Arguments, root: URL, version: String) -> [ToolchainCheck] {
        let sdk = AndroidToolchain.sdkDirectory(arguments)
        let install = "Install Android Studio / Command-line Tools from https://developer.android.com/studio. "
            + "In SDK Manager install platform-tools, platforms;android-36, build-tools;36.1.0 and NDK r30. "
            + "Command line: sdkmanager --sdk_root=\"\(sdk.path)\" \"platform-tools\" \"platforms;android-36\" \"build-tools;36.1.0\" \"ndk;30.0.16248370\". Review licenses using sdkmanager --licenses."
        var checks = [ToolchainCheck.executable("java", remedy: "Install JDK 21 (https://adoptium.net/) and set JAVA_HOME and PATH to it.")]
        // Java writes its version to stderr; javac reports to stdout on supported JDKs.
        let javac = (try? Shell.run(["javac", "-version"], capture: true, quiet: true)) ?? ""
        checks.append(.init(name: "JDK 21", ready: javac.hasPrefix("javac 21."), remedy: "Select JDK 21 using JAVA_HOME and PATH; run javac -version to verify."))
        for path in ["platform-tools/adb", "platforms/android-36/android.jar", "build-tools/36.1.0/apksigner", "build-tools/36.1.0/zipalign"] {
            #if os(Windows)
            let suffix = path.hasSuffix("adb") || path.hasSuffix("zipalign") ? ".exe" : path.hasSuffix("apksigner") ? ".bat" : ""
            #else
            let suffix = ""
            #endif
            checks.append(.init(name: "Android SDK \(path)", ready: FileManager.default.fileExists(atPath: sdk.appendingPathComponent(path + suffix).path), remedy: install))
        }
        let ndk = AndroidToolchain.ndkDirectory(arguments, root: root)
        let ndkVersion = (try? String(contentsOf: ndk.appendingPathComponent("source.properties"), encoding: .utf8)) ?? ""
        checks.append(.init(name: "NDK r30", ready: ndkVersion.range(of: #"Pkg.Revision\s*=\s*30\."#, options: .regularExpression) != nil, remedy: install + " Or supply --ndk PATH / ANDROID_NDK_HOME."))
        let sdks = version.isEmpty ? "" : (try? Shell.run([GuavaSDK.swift, "sdk", "list"], capture: true, quiet: true)) ?? ""
        checks.append(.init(name: "Swift Android SDK 6.4.1", ready: sdks.contains(AndroidToolchain.sdkID),
            remedy: "With the matching Swift 6.4.1 compiler, install the Android SDK and verify its published checksum: https://www.swift.org/install/android/. This target currently builds arm64-v8a / API 28+."))
        return checks
    }
}
