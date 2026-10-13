import GuavaAndroidContract
import Foundation

struct APKPackage {
    let toolchain: AndroidToolchain
    let identity: ApplicationIdentity
    let configuration: String
    let signing: APKSigning?

    func build(products: URL, launch: SceneLaunch, output: URL, project: URL? = nil, staging: URL? = nil) throws {
        let directory = staging ?? toolchain.cache.appendingPathComponent("apk-" + identity.id)
        try Files.reset(directory)
        let tools = toolchain.sdk.appendingPathComponent("build-tools/36.1.0")
        let androidJar = toolchain.sdk.appendingPathComponent("platforms/android-36/android.jar")
        let classes = directory.appendingPathComponent("classes"), stage = directory.appendingPathComponent("stage")
        try Files.directory(classes); try Files.directory(stage)
        let sources = try Files.files(toolchain.root.appendingPathComponent("Platforms/Android/App/src"))
            + Files.files(toolchain.root.appendingPathComponent("Engine/third-party/sdl3/android-project/app/src/main/java"))
        try Shell.run(["javac", "--release", "8", "-Xlint:-options", "-classpath", androidJar.path, "-d", classes.path]
            + sources.filter { $0.pathExtension == "java" }.map(\.path))
        try Shell.run([tools.appendingPathComponent("d8").path, "--min-api", "28", "--output", stage.path]
            + Files.files(classes).filter { $0.pathExtension == "class" }.map(\.path))
        let manifest = directory.appendingPathComponent("AndroidManifest.xml")
        try writeManifest(to: manifest)
        let base = directory.appendingPathComponent("base.apk"), aligned = directory.appendingPathComponent("aligned.apk")
        try Shell.run([tools.appendingPathComponent("aapt2").path, "link", "-I", androidJar.path, "--manifest", manifest.path, "-o", base.path])
        try APKAssets.stage(products: products, toolchain: toolchain, launch: launch, project: project, directory: stage)
        // JDK's ZIP writer avoids introducing a separate archive or Python dependency.
        try Shell.run(["jar", "uf", base.path, "-C", stage.path, "."])
        try Shell.run([tools.appendingPathComponent("zipalign").path, "-f", "-P", "16", "4", base.path, aligned.path])
        try Files.directory(output.deletingLastPathComponent())
        try APKSigning.sign(aligned: aligned, output: output, toolchain: toolchain, signing: signing)
        print("Built signed APK: \(output.path) (configuration=\(configuration))")
    }

    private func writeManifest(to destination: URL) throws {
        let template = try String(contentsOf: toolchain.root.appendingPathComponent("Platforms/Android/App/AndroidManifest.xml"), encoding: .utf8)
        let manifest = template.replacingOccurrences(of: "package=\"com.guava.probe\"", with: "package=\"\(identity.id)\"")
            .replacingOccurrences(of: "android:label=\"GuavaUI Gallery\"", with: "android:label=\"\(xml(identity.name))\"")
            .replacingOccurrences(of: "android:debuggable=\"true\"", with: "android:debuggable=\"\(configuration == "debug")\"")
            .replacingOccurrences(of: "android:name=\".MainActivity\"", with: "android:name=\"com.guava.probe.MainActivity\"")
        try Files.text(manifest, to: destination)
    }

    private func xml(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
