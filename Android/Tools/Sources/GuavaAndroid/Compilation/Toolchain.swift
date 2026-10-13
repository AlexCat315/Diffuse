import Foundation

struct AndroidToolchain {
    static let sdkID = "swift-6.4.1-RELEASE_android"
    static let triple = "aarch64-unknown-linux-android28"
    let root: URL
    let cache: URL
    let sdk: URL
    let ndk: URL
    let swift: String

    init(root: URL, arguments: Arguments) throws {
        self.root = root
        cache = root.appendingPathComponent("Engine/build/android-validation")
        let environment = ProcessInfo.processInfo.environment
        #if os(macOS)
        let defaultSDK = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk")
        #else
        let defaultSDK = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Android/Sdk")
        #endif
        sdk = arguments.url("android-sdk") ?? (environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"]).map { URL(fileURLWithPath: $0) } ?? defaultSDK
        ndk = arguments.url("ndk") ?? environment["ANDROID_NDK_HOME"].map { URL(fileURLWithPath: $0) } ?? cache.appendingPathComponent("android-ndk-r30")
        swift = environment["GUAVA_SWIFT_EXECUTABLE"] ?? "swift"
        let revision = try String(contentsOf: ndk.appendingPathComponent("source.properties"), encoding: .utf8)
        guard revision.range(of: #"Pkg.Revision\s*=\s*30\."#, options: .regularExpression) != nil else {
            throw ToolError.invalid("Swift 6.4 Android SDK requires NDK r30; supply --ndk")
        }
        let version = try Shell.run([swift, "--version"], capture: true)
        guard version.contains("swift-6.4.1-RELEASE") else {
            throw ToolError.invalid("Select the Swift 6.4.1 release toolchain matching the Android SDK")
        }
    }

    func ndkHost() throws -> URL {
        let hosts = try Files.children(ndk.appendingPathComponent("toolchains/llvm/prebuilt"))
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard hosts.count == 1 else { throw ToolError.invalid("Expected one NDK host toolchain") }
        return hosts[0]
    }

    func compile(product: String, configuration: String, content: URL? = nil,
                 gameplay: URL? = nil, scratch: URL? = nil) throws -> URL {
        try Files.directory(cache)
        let artifacts = try NativeDependencies(toolchain: self).prepare()
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_NDK_HOME"] = ndk.path
        // SwiftPM resolves binary target paths against the consuming package root, so the
        // shared cache locations are passed relative to the package that reads them.
        environment["GUAVA_ENGINE_ARTIFACT_ROOT"] =
            artifactRoot(artifacts.engine.path, relativeTo: root.appendingPathComponent("Engine").path)
        environment["GUAVA_TEXT_ARTIFACT_ROOT"] =
            artifactRoot(artifacts.text.path, relativeTo: root.appendingPathComponent("GuavaUI/Text").path)
        environment["GUAVA_ANDROID_UI_PACKAGE"] = content?.path
        environment["GUAVA_ANDROID_GAME_PACKAGE"] = gameplay?.path
        var command = [swift, "build", "--package-path", root.appendingPathComponent("Android").path,
                       "--swift-sdk", Self.sdkID, "--triple", Self.triple, "--static-swift-stdlib",
                       "--configuration", configuration, "--jobs", "4"]
        if let scratch { command += ["--scratch-path", scratch.path] }
        try Shell.run(command + ["--product", product], environment: environment)
        return URL(fileURLWithPath: try Shell.run(command + ["--show-bin-path"], environment: environment, capture: true))
    }
}

/// SwiftPM only accepts package relative binary target paths, so shared cache
/// directories are resolved against the package that declares the target.
private func artifactRoot(_ path: String, relativeTo base: String) -> String {
    let target = path.split(separator: "/").map(String.init)
    let prefix = base.split(separator: "/").map(String.init)
    var shared = 0
    while shared < target.count, shared < prefix.count, target[shared] == prefix[shared] { shared += 1 }
    let ascend = prefix[shared...].map { _ in ".." }
    return (ascend + target[shared...]).joined(separator: "/")
}
