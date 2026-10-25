public import Foundation
internal import GuavaProcess
import ScriptRuntime

public struct SwiftToolchain: Sendable, Equatable {
    public let compilerURL: URL
    public let languageServerURL: URL
    public let rootURL: URL
    public let version: String
    public let sdkURL: URL?
    let environment: [String: String]
}

public enum SwiftToolchainError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case invalidInstallation(String)
    case confirmationRequired
    case unsupportedPlatform
    case installationInProgress

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .invalidInstallation(message): message
        case .confirmationRequired: "Confirm the official Swift toolchain download before installing."
        case .unsupportedPlatform: "Automatic installation is not available for this platform. Install a Swift toolchain from swift.org and select its path."
        case .installationInProgress: "A Swift toolchain installation is already in progress."
        }
    }
}

public enum SwiftToolchainResolver {
    public static func resolve(compilerOverride: String? = nil,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               preferences: SwiftToolchainPreferences = .load()) throws -> SwiftToolchain {
        let explicit = [compilerOverride, environment["GUAVA_SWIFTC_PATH"], environment["GUAVA_SWIFT_TOOLCHAIN_PATH"],
                        preferences.selectedPath].compactMap { value -> String? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }.first
        if let explicit {
            return try inspect(compilerURL: compilerURL(at: explicit, environment: environment), environment: environment)
        } else if let lsp = environment[SourceKitLSPExecutableLocator.overrideEnvironmentKey], !lsp.isEmpty {
            let executable = try SwiftScriptCompiler.resolveExecutableURL(for: lsp, environment: environment)
            return try inspect(compilerURL: compilerURL(at: executable.deletingLastPathComponent().path, environment: environment), environment: environment)
        }
        var candidates = [URL]()
        if let found = try? SwiftScriptCompiler.resolveExecutableURL(for: "swiftc", environment: environment) { candidates.append(found) }
        if let found = try? xcrun("--find", "swiftc", environment: environment) { candidates.append(URL(fileURLWithPath: found)) }
        for release in SwiftToolchainInstallation.releases {
            let path = SwiftToolchainPreferences.directory.appendingPathComponent("Installed/swift-\(release.version).xctoolchain").path
            if let found = try? compilerURL(at: path, environment: environment) { candidates.append(found) }
        }
        var failures = [String]()
        for candidate in candidates {
            do { return try inspect(compilerURL: candidate, environment: environment) }
            catch { failures.append(error.localizedDescription) }
        }
        throw SwiftToolchainError.unavailable(failures.isEmpty
            ? "No Swift toolchain was found. Select a toolchain path or install an official Swift release."
            : failures.joined(separator: "\n"))
    }

    public static func installed(environment: [String: String] = ProcessInfo.processInfo.environment) -> [SwiftToolchain] {
        var candidates = [String]()
        if let current = try? resolve(environment: environment) { candidates.append(current.compilerURL.path) }
        if let xcode = try? xcrun("--find", "swiftc", environment: environment) { candidates.append(xcode) }
        var roots = [SwiftToolchainPreferences.directory.appendingPathComponent("Installed")]
        #if os(macOS)
        roots.append(contentsOf: [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Toolchains"),
                                  URL(fileURLWithPath: "/Library/Developer/Toolchains")])
        for directory in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            for application in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                where application.lastPathComponent.hasPrefix("Xcode") && application.pathExtension == "app" {
                candidates.append(application.path)
            }
        }
        #else
        let home = environment["SWIFTLY_TOOLCHAINS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/swiftly/toolchains")
        roots.append(home)
        #endif
        for root in roots {
            for directory in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                candidates.append(directory.path)
            }
        }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let compiler = try? compilerURL(at: candidate, environment: environment),
                  let toolchain = try? inspect(compilerURL: compiler, environment: environment),
                  seen.insert(toolchain.rootURL.path).inserted else { return nil }
            return toolchain
        }
    }

    static func compilerURL(at path: String, environment: [String: String]) throws -> URL {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            let root = URL(fileURLWithPath: path)
            for relative in ["usr/bin/\(compilerName)", "bin/\(compilerName)", compilerName,
                             "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/\(compilerName)"] {
                let candidate = root.appendingPathComponent(relative)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            throw SwiftToolchainError.unavailable("The selected directory does not contain swiftc: \(path)")
        }
        return try SwiftScriptCompiler.resolveExecutableURL(for: path, environment: environment)
    }

    static func inspect(compilerURL: URL, environment: [String: String]) throws -> SwiftToolchain {
        var launchEnvironment = environment
        let sdk: URL?
        #if os(macOS)
        let path = compilerURL.resolvingSymlinksInPath().path
        if let range = path.range(of: "/Contents/Developer/Toolchains/") {
            launchEnvironment["DEVELOPER_DIR"] = String(path[..<range.lowerBound]) + "/Contents/Developer"
        }
        if let configured = environment["SDKROOT"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("SDKSettings.json").path)
                    || FileManager.default.fileExists(atPath: url.appendingPathComponent("SDKSettings.plist").path) else {
                throw SwiftToolchainError.unavailable("The configured macOS SDK is invalid: \(configured)")
            }
            sdk = url
        } else {
            sdk = try URL(fileURLWithPath: xcrun("--sdk", "macosx", "--show-sdk-path", environment: launchEnvironment))
        }
        launchEnvironment["SDKROOT"] = sdk?.path
        #else
        sdk = environment["SDKROOT"].map { URL(fileURLWithPath: $0) }
        #endif
        let data = try probe(compilerURL, arguments: ["-print-target-info"], environment: launchEnvironment)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["paths"] as? [String: Any], let runtime = paths["runtimeResourcePath"] as? String,
              let version = object["compilerVersion"] as? String else {
            throw SwiftToolchainError.unavailable("Swift could not report its standard library paths: \(compilerURL.path)")
        }
        let runtimeURL = URL(fileURLWithPath: runtime).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            throw SwiftToolchainError.unavailable("Swift standard library directory is missing: \(runtime)")
        }
        let prefix = runtimeURL.deletingLastPathComponent().deletingLastPathComponent()
        let binaryDirectory = prefix.appendingPathComponent("bin")
        let fixedCompiler = binaryDirectory.appendingPathComponent(compilerName)
        let fixedLSP = binaryDirectory.appendingPathComponent(languageServerName)
        guard FileManager.default.isExecutableFile(atPath: fixedCompiler.path),
              FileManager.default.isExecutableFile(atPath: fixedLSP.path) else {
            throw SwiftToolchainError.unavailable("The Swift toolchain must include matching swiftc and sourcekit-lsp binaries: \(prefix.path)")
        }
        if let override = environment[SourceKitLSPExecutableLocator.overrideEnvironmentKey], !override.isEmpty {
            let selected = try SwiftScriptCompiler.resolveExecutableURL(for: override, environment: environment)
            let resolved = selected.resolvingSymlinksInPath()
            guard resolved.lastPathComponent == "swiftly" || resolved == fixedLSP.resolvingSymlinksInPath() else {
                throw SwiftToolchainError.unavailable("The configured SourceKit-LSP does not belong to the selected Swift compiler toolchain.")
            }
        }
        let root = prefix.lastPathComponent == "usr" ? prefix.deletingLastPathComponent() : prefix
        #if os(Windows)
        let separator = ";"
        #else
        let separator = ":"
        #endif
        launchEnvironment["PATH"] = binaryDirectory.path + separator + (environment["PATH"] ?? "")
        launchEnvironment["SOURCEKIT_TOOLCHAIN_PATH"] = root.path
        launchEnvironment["SWIFT_EXEC"] = fixedCompiler.path
        return SwiftToolchain(compilerURL: fixedCompiler, languageServerURL: fixedLSP, rootURL: root,
                              version: version, sdkURL: sdk, environment: launchEnvironment)
    }

    static func probe(_ executable: URL, arguments: [String], environment: [String: String]) throws -> Data {
        var command = ProcessCommand(executable: executable, directory: FileManager.default.temporaryDirectory)
        command.arguments = arguments
        command.environment = environment
        var budget = ProcessBudget()
        budget.lifetimeMilliseconds = 10_000
        budget.outputBytes = 1_048_576
        let output = try ProcessRunner.runSynchronously(command, budget: budget)
        guard output.status == 0 else {
            throw SwiftToolchainError.unavailable(String(decoding: output.stderr + output.stdout, as: UTF8.self))
        }
        return output.stdout
    }

    private static func xcrun(_ arguments: String..., environment: [String: String]) throws -> String {
        #if os(macOS)
        let executable = try SwiftScriptCompiler.resolveExecutableURL(for: "xcrun", environment: environment)
        let data = try probe(executable, arguments: arguments, environment: environment)
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw SwiftToolchainError.unavailable("Install Xcode or Command Line Tools to provide the macOS SDK.") }
        return path
        #else
        throw SwiftToolchainError.unavailable("xcrun is available only on macOS.")
        #endif
    }

    private static var compilerName: String {
        #if os(Windows)
        "swiftc.exe"
        #else
        "swiftc"
        #endif
    }

    private static var languageServerName: String {
        #if os(Windows)
        "sourcekit-lsp.exe"
        #else
        "sourcekit-lsp"
        #endif
    }
}
