import Foundation

@main
enum GuavaCLI {
    static func main() {
        do {
            let raw = Array(CommandLine.arguments.dropFirst())
            if raw.isEmpty || raw.contains("--help") { print(usage); return }
            try execute(Arguments(raw))
        } catch {
            FileHandle.standardError.write(Data("guava: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func execute(_ arguments: Arguments) throws {
        switch arguments.operation {
        case .create: try CreateApplication.run(arguments, root: GuavaSDK.locate(arguments))
        case .clean:
            let project = try AppProject(at: arguments.directory)
            try project.clean()
            print("Cleaned \(project.buildDirectory.path)")
        case .build, .run, .test:
            let project = try AppProject(at: arguments.directory)
            let root = try GuavaSDK.locate(arguments, project: project)
            if arguments.operation == .test { try SwiftPackage.test(project: project, root: root, arguments: arguments); return }
            try project.require(arguments.platform)
            if arguments.platform == .android { try BuildAndroidApplication.run(arguments, root: root, project: project) }
            else { try DesktopBuild(project: project, root: root, arguments: arguments).run() }
        case .devtools:
            let project = try AppProject(at: arguments.directory)
            try Inspector.attach(arguments, project: project, root: GuavaSDK.locate(arguments, project: project))
        case .androidPrepare:
            let project = try AppProject(at: arguments.directory)
            try BuildAndroidApplication.prepare(arguments, root: GuavaSDK.locate(arguments, project: project), project: project)
        case .sdkInstall: try SDKStore().install(source: arguments.subject!, revision: arguments.required(.revision))
        case .sdkUse: try SDKStore().use(arguments.directory)
        case .sdkList: try SDKStore().list()
        case .setup: try ToolchainSetup.run(arguments, root: GuavaSDK.locate(arguments))
        case .doctor: try Diagnostics.doctor(arguments, root: GuavaSDK.locate(arguments))
        case .devices: try Diagnostics.devices(arguments)
        case .exportGame:
            guard arguments.platform == .android else { throw ToolError.invalid("Game APK export currently requires --android") }
            try ExportGame.run(arguments, root: GuavaSDK.locate(arguments))
        case .showcase:
            guard arguments.platform == .android else { throw ToolError.invalid("Use swift run --package-path GuavaUI/Examples GuavaUIDemo for the desktop gallery; showcase currently targets --android") }
            try BuildAndroidApplication.run(arguments, root: GuavaSDK.locate(arguments))
        case .androidCompile: try compile(arguments, root: GuavaSDK.locate(arguments))
        }
    }

    private static func compile(_ arguments: Arguments, root: URL) throws {
        struct Result: Encodable { let products: String }
        let toolchain = try AndroidToolchain(root: root, arguments: arguments)
        let products = try toolchain.compile(product: arguments.required(.product), configuration: arguments.configuration,
            content: arguments.url(.contentPackage), gameplay: arguments.url(.gameplayPackage), scratch: arguments.url(.scratchPath))
        if let result = arguments.url(.resultFile) { try Files.json(Result(products: products.path), to: result) }
        else { print(products.path) }
    }

    static var usage: String {
        """
        Guava — create, build and run cross-platform Swift applications

          guava create app <directory> [--id com.example.app] [--name 'My App']
          guava build [directory] [--mac|--win|--linux|--android|--ios|--web] [--debug|--profile|--release]
          guava run   [directory] [--mac|--win|--linux|--android|--ios|--web] [--debug|--profile|--release]
          guava test  [directory] [--debug|--profile|--release] [--filter TEST]
          guava clean [directory]
          guava sdk install <repository> --revision COMMIT_OR_TAG
          guava sdk use <checkout> | guava sdk list
          guava setup [--mac|--win|--linux|--android]
          guava doctor [--mac|--win|--linux|--android]
          guava devices [--android]
          guava devtools [directory] [--session ID] [--no-open]

        Directory defaults to the current project; platform defaults to the host; configuration defaults to debug.
        One guava.json owns application identity, SDK location and targets; UI lives in Sources/AppContent.
        Desktop builds run on their matching host. Android uses Swift 6.4.1 + Android SDK, NDK r30 and JDK 21.
        iOS and Web application hosts are not yet implemented; selecting them reports an explicit error.

        SDK selection: --engine-root PATH, GUAVA_ENGINE_ROOT, guava.json's toolchain.enginePath, or the installed SDK selection.
        Run: --devtools [--no-open] opens the Inspector; --profile enables optimized diagnostics.
        Create: --platforms mac,android selects native project templates.
        Build/run: --output PATH; Android: --android-sdk PATH --ndk PATH --device SERIAL
        Android signing: --keystore FILE --key-alias ALIAS --store-password-env NAME --key-password-env NAME
        Release APKs use a development key unless custom signing is provided.

        Framework development:
          guava showcase [gallery|counter] --android [--component NAME] [--release]
          guava export game <project> --android --id com.example.game [--name NAME] [--output FILE.apk]
        """
    }
}
