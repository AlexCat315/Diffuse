import Foundation
import RHIWGPU

struct EditorAppLaunchOptions {
    let backendConfig: WGPUDeviceConfig
    let projectDirectory: String

    static func load(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> EditorAppLaunchOptions {
        let commandLine = try ParsedCommandLine(arguments: arguments)
        let configPath = commandLine.configPath
            ?? environment["GUAVA_WGPU_CONFIG"]

        let fileConfig = try configPath.map(Self.loadConfigFile)

        let preferredBackends = try resolvePreferredBackends(
            commandLineValue: commandLine.backendList,
            environmentValue: environment["GUAVA_WGPU_BACKENDS"],
            fileValue: fileConfig?.wgpu?.preferredBackends
        )

        let validationEnabled = fileConfig?.wgpu?.validationEnabled ?? true
        let framesInFlight = fileConfig?.wgpu?.framesInFlight ?? 2
        let libraryPath = fileConfig?.wgpu?.libraryPath
        let projectDirectory = commandLine.projectDirectory
            ?? environment["GUAVA_PROJECT_DIR"]
            ?? FileManager.default.currentDirectoryPath

        return EditorAppLaunchOptions(
            backendConfig: WGPUDeviceConfig(
                validationEnabled: validationEnabled,
                framesInFlight: framesInFlight,
                libraryPath: libraryPath,
                preferredBackends: preferredBackends
            ),
            projectDirectory: projectDirectory
        )
    }

    private static func resolvePreferredBackends(
        commandLineValue: String?,
        environmentValue: String?,
        fileValue: [String]?
    ) throws -> [WGPUBackendPreference] {
        if let commandLineValue {
            return try parseBackendList(commandLineValue)
        }

        if let environmentValue {
            return try parseBackendList(environmentValue)
        }

        if let fileValue {
            return try fileValue.map(parseBackendName)
        }

        return WGPUBackendPreference.platformDefaultOrder
    }

    private static func parseBackendList(_ rawValue: String) throws -> [WGPUBackendPreference] {
        let names = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if names.isEmpty {
            throw EditorAppLaunchError.invalidBackendList(rawValue)
        }

        return try names.map(parseBackendName)
    }

    private static func parseBackendName(_ rawName: String) throws -> WGPUBackendPreference {
        switch rawName.lowercased() {
            case "auto", "automatic":
                return .automatic
            case "d3d11", "dx11":
                return .d3d11
            case "d3d12", "dx12":
                return .d3d12
            case "metal":
                return .metal
            case "vulkan":
                return .vulkan
            case "opengl", "gl":
                return .openGL
            case "opengles", "gles":
                return .openGLES
            default:
                throw EditorAppLaunchError.invalidBackendName(rawName)
        }
    }

    private static func loadConfigFile(at path: String) throws -> EditorAppConfigFile {
        let fileURL = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(EditorAppConfigFile.self, from: data)
        } catch {
            throw EditorAppLaunchError.invalidConfigFile(path: path, underlying: error)
        }
    }
}

private struct ParsedCommandLine {
    let backendList: String?
    let configPath: String?
    let projectDirectory: String?

    init(arguments: [String]) throws {
        var backendList: String?
        var configPath: String?
        var projectDirectory: String?

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
                case "--wgpu-backends":
                    index += 1
                    guard index < arguments.count else {
                        throw EditorAppLaunchError.missingValue(argument)
                    }
                    backendList = arguments[index]

                case let value where value.hasPrefix("--wgpu-backends="):
                    backendList = String(value.dropFirst("--wgpu-backends=".count))

                case "--wgpu-config":
                    index += 1
                    guard index < arguments.count else {
                        throw EditorAppLaunchError.missingValue(argument)
                    }
                    configPath = arguments[index]

                case let value where value.hasPrefix("--wgpu-config="):
                    configPath = String(value.dropFirst("--wgpu-config=".count))

                case "--project-dir":
                    index += 1
                    guard index < arguments.count else {
                        throw EditorAppLaunchError.missingValue(argument)
                    }
                    projectDirectory = arguments[index]

                case let value where value.hasPrefix("--project-dir="):
                    projectDirectory = String(value.dropFirst("--project-dir=".count))

                default:
                    break
            }
            index += 1
        }

        self.backendList = backendList
        self.configPath = configPath
        self.projectDirectory = projectDirectory
    }
}

private struct EditorAppConfigFile: Decodable {
    let wgpu: WGPUSection?

    struct WGPUSection: Decodable {
        let preferredBackends: [String]?
        let validationEnabled: Bool?
        let framesInFlight: UInt32?
        let libraryPath: String?
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