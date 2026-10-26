internal import Foundation
internal import ToolSupport
internal import MediaStaging

/// Studio owns project/script export; the SDK owns platform compilation and APK assembly.
enum AndroidExport {
    static func run(_ arguments: [String]) throws {
        guard let first = arguments.first, !first.hasPrefix("--") else {
            throw ToolError.message("Use ./cove studio export-game PROJECT --id com.example.game [--name NAME] [--output FILE.apk]")
        }
        let project = URL(fileURLWithPath: first).standardizedFileURL
        let options = Array(arguments.dropFirst())
        func option(_ name: String) throws -> String? {
            let indices = options.indices.filter { options[$0] == name }
            guard indices.count <= 1 else { throw ToolError.message("Duplicate option: \(name)") }
            guard let index = indices.first else { return nil }
            guard options.indices.contains(index + 1), !options[index + 1].hasPrefix("--") else {
                throw ToolError.message("Missing value: \(name)")
            }
            return options[index + 1]
        }
        guard try option("--id") != nil else { throw ToolError.message("Supply --id com.example.game") }
        let name = try option("--name") ?? project.lastPathComponent
        let output = URL(fileURLWithPath: try option("--output") ?? project.appendingPathComponent("build/\(project.lastPathComponent).apk").path)
        let root = Repository.root
        let sdk = root.appendingPathComponent("CoveUI")
        let directory = root.appendingPathComponent("build/android-export/" + UUID().uuidString)
        let staged = directory.appendingPathComponent("Project")
        let gameplay = directory.appendingPathComponent("CoveAndroidGameplay")
        let compiler = ProcessInfo.processInfo.environment["COVE_SWIFT_EXECUTABLE"] ?? "swift"
        let command = [compiler, "build", "--package-path", root.appendingPathComponent("Editor").path, "--jobs", "4"]
        try Shell.inherit(command + ["--product", "CoveProjectExport"])
        let products = try Shell.output(command + ["--show-bin-path"])
        #if os(Windows)
        let exporter = "CoveProjectExport.exe", cli = "cove.cmd"
        #else
        let exporter = "CoveProjectExport", cli = "cove"
        #endif
        try Shell.inherit([URL(fileURLWithPath: products).appendingPathComponent(exporter).path,
            "--project", project.path, "--output", staged.path, "--static-scripts", "--name", name])
        _ = try GameplayPackage.create(project: staged, destination: gameplay, root: root)
        var environment = ProcessInfo.processInfo.environment
        let ndk = try option("--ndk").map { URL(fileURLWithPath: $0) } ?? findNDK(sdk: sdk)
        environment["ANDROID_NDK_HOME"] = ndk.path
        try prepareNative(root: root, ndk: ndk, environment: environment)
        environment["COVE_ENGINE_ARTIFACT_ROOT"] = "build/android-native/vendor"
        try Shell.inherit([sdk.appendingPathComponent(cli).path, "internal", "android-export"] + options
            + (try option("--name") == nil ? ["--name", name] : [])
            + (try option("--output") == nil ? ["--output", output.path] : [])
            + ["--sdk-root", sdk.path, "--host-package", root.appendingPathComponent("Platforms/Android").path,
               "--gameplay-package", gameplay.path, "--project-assets", staged.path], environment: environment)
        try Fs.copy(staged.appendingPathComponent("build.json"), to: output.deletingPathExtension().appendingPathExtension("project.json"))
    }

    private static func findNDK(sdk: URL) -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ANDROID_NDK_HOME"] { return URL(fileURLWithPath: path) }
        #if os(macOS)
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk")
        #else
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Android/Sdk")
        #endif
        let android = (environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"]).map { URL(fileURLWithPath: $0) } ?? fallback
        let installed = (try? FileManager.default.contentsOfDirectory(at: android.appendingPathComponent("ndk"), includingPropertiesForKeys: nil)) ?? []
        return installed.filter { $0.lastPathComponent.hasPrefix("30.") }.sorted { $0.path < $1.path }.last
            ?? sdk.appendingPathComponent("build/android-validation/android-ndk-r30")
    }

    private static func prepareNative(root: URL, ndk: URL, environment: [String: String]) throws {
        let build = root.appendingPathComponent("Engine/build/android-native")
        try Shell.inherit(["cmake", "-S", root.appendingPathComponent("Engine/third-party").path, "-B", build.path,
            "-G", "Ninja", "-DCMAKE_TOOLCHAIN_FILE=\(ndk.path)/build/cmake/android.toolchain.cmake",
            "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM=android-28", "-DANDROID_STL=c++_shared",
            "-DCMAKE_BUILD_TYPE=Release", "-DCOVE_VENDOR_DIR=\(build.path)/vendor"], environment: environment)
        try Shell.inherit(["cmake", "--build", build.path, "--parallel", "4"], environment: environment)
        try Shell.inherit(["cmake", "--install", build.path], environment: environment)
        try MediaStaging.run(["--platform", "android-arm64"], environment: environment)
    }
}
