import Foundation

enum Operation: Equatable {
    case setup, sdkInstall, sdkUse, sdkList, create, build, run, clean, test, doctor, devices, exportGame, showcase, androidCompile, androidPrepare, devtools
}

enum Option: String, CaseIterable {
    case simulator, team
    case revision
    case engineRoot = "engine-root", id, name, output, device, filter, platforms, session
    case androidSDK = "android-sdk", ndk, keystore, keyAlias = "key-alias"
    case storePassword = "store-password-env", keyPassword = "key-password-env"
    case component, product, contentPackage = "content-package", gameplayPackage = "gameplay-package"
    case scratchPath = "scratch-path", resultFile = "result-file"
}

/// Parses one command grammar. Platform backends consume the same request.
struct Arguments {
    let operation: Operation
    let subject: String?
    let platform: AppPlatform
    let requestedPlatform: AppPlatform?
    let configuration: BuildConfiguration
    let flags: Set<Flag>
    private let values: [Option: String]

    init(_ raw: [String]) throws {
        var tokens = raw[...]
        guard let verb = tokens.popFirst() else { throw ToolError.invalid("Supply a command; use guava --help") }
        let operation: Operation
        switch verb {
        case "create":
            guard tokens.popFirst() == "app" else { throw ToolError.invalid("Use guava create app <directory>") }
            operation = .create
        case "build": operation = .build
        case "run": operation = .run
        case "clean": operation = .clean
        case "test": operation = .test
        case "doctor": operation = .doctor
        case "setup": operation = .setup
        case "sdk":
            switch tokens.popFirst() {
            case "install": operation = .sdkInstall
            case "use": operation = .sdkUse
            case "list": operation = .sdkList
            default: throw ToolError.invalid("Use guava sdk install/use/list")
            }
        case "devices": operation = .devices
        case "showcase": operation = .showcase
        case "devtools": operation = .devtools
        case "export":
            guard tokens.popFirst() == "game" else { throw ToolError.invalid("Use guava export game <project> --android") }
            operation = .exportGame
        case "internal":
            switch tokens.popFirst() {
            case "android-compile": operation = .androidCompile
            case "android-prepare": operation = .androidPrepare
            default: throw ToolError.invalid("Unknown internal operation")
            }
        default: throw ToolError.invalid("Unknown command '\(verb)'; use guava --help")
        }
        var values: [Option: String] = [:], subject: String?
        var flags: Set<Flag> = []
        var platform: AppPlatform?, configuration: BuildConfiguration?
        while let token = tokens.popFirst() {
            if token.hasPrefix("--"), let candidate = AppPlatform(rawValue: String(token.dropFirst(2))) {
                guard platform == nil else { throw ToolError.invalid("Select exactly one platform") }
                platform = candidate
            } else if token.hasPrefix("--"), let flag = Flag(rawValue: String(token.dropFirst(2))) {
                guard (operation == .run || (operation == .devtools && flag == .noOpen)), flags.insert(flag).inserted else {
                    throw ToolError.invalid("Unexpected or duplicate flag: \(token)")
                }
            } else if token == "--debug" || token == "--release" || token == "--profile" {
                guard configuration == nil else { throw ToolError.invalid("Select exactly one of --debug, --profile or --release") }
                configuration = BuildConfiguration(rawValue: String(token.dropFirst(2)))!
            } else if token.hasPrefix("--"), let key = Option(rawValue: String(token.dropFirst(2))) {
                guard Self.allowed(operation).contains(key), values[key] == nil,
                      let value = tokens.popFirst(), !value.isEmpty, !value.hasPrefix("--") else {
                    throw ToolError.invalid("Unknown, duplicate or missing value for \(token)")
                }
                values[key] = value
            } else if !token.hasPrefix("--"), subject == nil {
                subject = token
            } else { throw ToolError.invalid("Unexpected argument: \(token)") }
        }
        if [.create, .exportGame, .sdkInstall, .sdkUse].contains(operation) {
            guard subject != nil else { throw ToolError.invalid("Supply a project directory") }
        }
        if [.doctor, .setup, .sdkList, .devices, .androidCompile].contains(operation), subject != nil {
            throw ToolError.invalid("This command does not take a project directory")
        }
        if [.create, .clean, .test].contains(operation), platform != nil {
            throw ToolError.invalid("\(verb) is project-wide and does not take a platform flag")
        }
        if configuration != nil, ![.build, .run, .test, .showcase, .exportGame, .androidCompile, .androidPrepare].contains(operation) {
            throw ToolError.invalid("\(verb) does not take a build configuration")
        }
        let selectedPlatform = platform ?? ([.androidCompile, .androidPrepare, .exportGame, .showcase].contains(operation) ? .android : .host)
        if [.androidCompile, .androidPrepare, .exportGame, .showcase].contains(operation), selectedPlatform != .android {
            throw ToolError.invalid("This operation currently requires --android")
        }
        let androidOnly: Set<Option> = [.androidSDK, .ndk, .keystore, .keyAlias, .storePassword, .keyPassword, .component]
        if selectedPlatform != .android, !Set(values.keys).isDisjoint(with: androidOnly) {
            throw ToolError.invalid("Android options require --android")
        }
        if operation == .build && selectedPlatform == .android && values[.device] != nil {
            throw ToolError.invalid("Android --device is a run option")
        }
        if values[.device] != nil && ![AppPlatform.android, .ios].contains(selectedPlatform) {
            throw ToolError.invalid("--device requires --android or --ios")
        }
        if (values[.simulator] != nil || values[.team] != nil) && selectedPlatform != .ios {
            throw ToolError.invalid("--simulator and --team require --ios")
        }
        if values[.simulator] != nil && values[.device] != nil {
            throw ToolError.invalid("Select either --simulator or --device")
        }
        if configuration == .release, flags.contains(.devtools) {
            throw ToolError.invalid("DevTools requires --debug or --profile")
        }
        if flags.contains(.noOpen), operation == .run, !flags.contains(.devtools) {
            throw ToolError.invalid("--no-open requires --devtools")
        }
        self.flags = flags
        self.operation = operation
        self.subject = subject
        self.platform = selectedPlatform
        self.requestedPlatform = platform
        self.configuration = configuration ?? .debug
        self.values = values
    }

    func value(_ option: Option) -> String? { values[option] }
    func required(_ option: Option) throws -> String {
        guard let value = values[option], !value.isEmpty else { throw ToolError.invalid("Supply --\(option.rawValue)") }
        return value
    }
    func url(_ option: Option) -> URL? { values[option].map { URL(fileURLWithPath: $0).standardizedFileURL } }
    var directory: URL { URL(fileURLWithPath: subject ?? FileManager.default.currentDirectoryPath).standardizedFileURL }

    private static func allowed(_ operation: Operation) -> Set<Option> {
        let common: Set<Option> = [.engineRoot]
        let android: Set<Option> = [.androidSDK, .ndk, .keystore, .keyAlias, .storePassword, .keyPassword]
        switch operation {
        case .create: return common.union([.id, .name, .platforms])
        case .build: return common.union(android).union([.output, .device, .simulator, .team])
        case .run: return common.union(android).union([.output, .device, .simulator, .team])
        case .test: return common.union([.filter])
        case .clean: return []
        case .sdkInstall: return [.revision]
        case .sdkUse, .sdkList: return []
        case .setup, .doctor: return common.union([.androidSDK, .ndk])
        case .devices: return [.androidSDK]
        case .exportGame: return common.union(android).union([.id, .name, .output])
        case .showcase: return common.union(android).union([.output, .component, .device])
        case .devtools: return common.union([.session])
        case .androidPrepare: return common.union([.ndk])
        case .androidCompile: return common.union([.ndk, .product, .contentPackage, .gameplayPackage, .scratchPath, .resultFile])
        }
    }
}

enum Flag: String { case devtools, noOpen = "no-open" }
