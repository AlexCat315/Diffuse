import Foundation

@main
enum GuavaAndroidCLI {
    static func main() {
        do {
            let raw = Array(CommandLine.arguments.dropFirst())
            if raw.isEmpty || raw.contains("--help") { print(usage); return }
            let arguments = try Arguments(raw)
            var sourceRoot = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { sourceRoot.deleteLastPathComponent() }
            let root = arguments.url("engine-root")
                ?? ProcessInfo.processInfo.environment["GUAVA_ENGINE_ROOT"].map { URL(fileURLWithPath: $0).standardizedFileURL }
                ?? sourceRoot
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Android/Package.swift").path) else {
                throw ToolError.invalid("Set GUAVA_ENGINE_ROOT or --engine-root to the Guava-Engine checkout")
            }
            switch arguments.command {
            case "create": try CreateApplication.run(arguments, root: root)
            case "build": try BuildApplication.run(arguments, root: root)
            case "export-game": try ExportGame.run(arguments, root: root)
            default: try compile(arguments, root: root)
            }
        } catch {
            FileHandle.standardError.write(Data("GuavaAndroid: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func compile(_ arguments: Arguments, root: URL) throws {
        struct Result: Encodable { let products: String }
        let toolchain = try AndroidToolchain(root: root, arguments: arguments)
        let options = try BuildOptions(arguments)
        let products = try toolchain.compile(product: arguments.required("product"), configuration: options.configuration,
            content: arguments.url("content-package"), gameplay: arguments.url("gameplay-package"), scratch: arguments.url("scratch-path"))
        if let result = arguments.url("result-file") { try Files.json(Result(products: products.path), to: result) }
        else { print(products.path) }
    }

    private static var usage: String {
        """
        GuavaAndroid — Swift-native Android tooling (no Python required)

          swift run --package-path Android/Tools GuavaAndroid create \\
            --directory /path/to/MyApp --application-id com.example.myapp --name 'My App'
          swift run --package-path Android/Tools GuavaAndroid build --app /path/to/MyApp --install
          swift run --package-path Android/Tools GuavaAndroid build --demo gallery --component textField
          swift run --package-path Android/Tools GuavaAndroid export-game \\
            --project examples/CrystalRush --application-id com.example.game --output /path/to/Game.apk

        Build / export options:
          --configuration debug|release   --output FILE.apk   --install   --serial DEVICE
          --android-sdk PATH   --ndk PATH   --application-id ID   --name LABEL
          --keystore FILE   --key-alias ALIAS
          --store-password-env NAME   --key-password-env NAME

        Engine checkout: GUAVA_ENGINE_ROOT or --engine-root PATH.
        Android builds require Swift 6.4.1 release + matching Swift Android SDK,
        NDK r30, Android SDK 36 / build-tools 36.1.0, JDK 21, CMake and Ninja.
        """
    }
}
