import Foundation
import NativeRHI

struct EditorAppLaunchOptions {
    let backendConfig: DeviceConfig
    let projectDirectory: String?
    let useLegacy: Bool
    let validateInstall: Bool

    static func load(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> EditorAppLaunchOptions {
        let commandLine = try ParsedCommandLine(arguments: arguments)
        let configPath = commandLine.configPath
            ?? environment["GUAVA_RHI_CONFIG"]

        let fileConfig = try configPath.map(Self.loadConfigFile)

        let preferredBackends = try resolvePreferredBackends(
            commandLineValue: commandLine.backendList,
            environmentValue: environment["GUAVA_RHI_BACKENDS"],
            fileValue: fileConfig?.rhi?.preferredBackends
        )

        let validationEnabled = fileConfig?.rhi?.validationEnabled ?? true
        let framesInFlight = fileConfig?.rhi?.framesInFlight ?? 2
        let projectDirectory = commandLine.projectDirectory
            ?? environment["GUAVA_PROJECT_DIR"]

        let useLegacy = commandLine.useLegacy
            || environment["GUAVA_LEGACY"] == "1"

        return EditorAppLaunchOptions(
            backendConfig: DeviceConfig(
                preferredBackends: preferredBackends,
                enableValidation: validationEnabled,
                framesInFlight: framesInFlight
            ),
            projectDirectory: projectDirectory,
            useLegacy: useLegacy,
            validateInstall: commandLine.validateInstall
        )
    }

    private static func resolvePreferredBackends(
        commandLineValue: String?,
        environmentValue: String?,
        fileValue: [String]?
    ) throws -> [GraphicsAPI] {
        if let commandLineValue {
            return try parseBackendList(commandLineValue)
        }

        if let environmentValue {
            return try parseBackendList(environmentValue)
        }

        if let fileValue {
            return try fileValue.map(parseBackendName)
        }

        return NativeRHI.platformDefaultBackends
    }

    private static func parseBackendList(_ rawValue: String) throws -> [GraphicsAPI] {
        let names = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if names.isEmpty {
            throw EditorAppLaunchError.invalidBackendList(rawValue)
        }

        return try names.map(parseBackendName)
    }

    private static func parseBackendName(_ rawName: String) throws -> GraphicsAPI {
        switch rawName.lowercased() {
            case "dx12":
                return .dx12
            case "metal":
                return .metal
            case "vulkan":
                return .vulkan
            default:
                throw EditorAppLaunchError.invalidBackendName(rawName)
        }
    }

    private static func loadConfigFile(at path: String) throws -> EditorApplicationConfigurationFile {
        let fileURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(EditorApplicationConfigurationFile.self, from: data)
        } catch {
            throw EditorAppLaunchError.invalidConfigFile(path: path, underlying: error)
        }
    }
}

extension EditorAppLaunchOptions {
    /// Opt-in developer watch for enabled plugin packages (`--watch-plugins`,
    /// `GUAVA_WATCH_PLUGINS=1`). Watching never authorizes changed packages:
    /// byte-identical builds are remounted, and anything else is surfaced for
    /// review in the plugin management flow.
    static var watchPluginPackagesRequested: Bool {
        CommandLine.arguments.contains("--watch-plugins")
            || ProcessInfo.processInfo.environment["GUAVA_WATCH_PLUGINS"] == "1"
    }
}

private struct ParsedCommandLine {
    let backendList: String?
    let configPath: String?
    let projectDirectory: String?
    let useLegacy: Bool
    let validateInstall: Bool

    init(arguments: [String]) throws {
        var backendList: String?
        var configPath: String?
        var projectDirectory: String?
        var useLegacy = false
        var validateInstall = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
                case "--rhi-backends":
                    index += 1
                    guard index < arguments.count else {
                        throw EditorAppLaunchError.missingValue(argument)
                    }
                    backendList = arguments[index]

                case let value where value.hasPrefix("--rhi-backends="):
                    backendList = String(value.dropFirst("--rhi-backends=".count))

                case "--rhi-config":
                    index += 1
                    guard index < arguments.count else {
                        throw EditorAppLaunchError.missingValue(argument)
                    }
                    configPath = arguments[index]

                case let value where value.hasPrefix("--rhi-config="):
                    configPath = String(value.dropFirst("--rhi-config=".count))

                case "--project-dir":
                    index += 1
                    guard index < arguments.count else {
                        throw EditorAppLaunchError.missingValue(argument)
                    }
                    projectDirectory = arguments[index]

                case let value where value.hasPrefix("--project-dir="):
                    projectDirectory = String(value.dropFirst("--project-dir=".count))

                case "--legacy":
                    useLegacy = true

                case "--validate-install":
                    validateInstall = true

                default:
                    break
            }
            index += 1
        }

        self.backendList = backendList
        self.configPath = configPath
        self.projectDirectory = projectDirectory
        self.useLegacy = useLegacy
        self.validateInstall = validateInstall
    }
}

private struct EditorApplicationConfigurationFile: Decodable {
    let rhi: RHISection?

    struct RHISection: Decodable {
        let preferredBackends: [String]?
        let validationEnabled: Bool?
        let framesInFlight: Int?
    }
}

private enum EditorAppLaunchError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidBackendList(String)
    case invalidBackendName(String)
    case invalidConfigFile(path: String, underlying: Error)

    var description: String {
        switch self {
            case let .missingValue(flag):
                return "missing value for \(flag)"
            case let .invalidBackendList(rawValue):
                return "invalid backend list: \(rawValue)"
            case let .invalidBackendName(name):
                return "unsupported backend name: \(name)"
            case let .invalidConfigFile(path, underlying):
                return "failed to load config file at \(path): \(underlying)"
        }
    }
}
