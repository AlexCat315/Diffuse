import Foundation
import EngineKernel

public enum PlayerInstallValidationError: Error, Equatable, CustomStringConvertible {
    case executableLocationUnavailable
    case missingComponents([String])

    public var description: String {
        switch self {
        case .executableLocationUnavailable:
            return "GuavaPlayer installation validation could not locate the executable."
        case let .missingComponents(components):
            return "GuavaPlayer installation is incomplete; missing: "
                + components.joined(separator: ", ")
        }
    }
}

/// Validates the resource layout used by both release archives and exported games.
public enum PlayerInstallValidator {
    private static let resourceBundleBases = [
        "GuavaEditor_EditorCore",
        "GuavaEngine_RenderBackend",
        "GuavaUI_GuavaUIApp",
        "GuavaUI_GuavaUICompose",
        "GuavaUI_GuavaUIWorkspace",
    ]

    public static func validateLayout(
        executableURL: URL? = nil,
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        arguments: [String] = CommandLine.arguments
    ) throws -> String {
        guard let executableURL = executableURL
            ?? bundleExecutableURL
            ?? arguments.first.map({ URL(fileURLWithPath: $0) }) else {
            throw PlayerInstallValidationError.executableLocationUnavailable
        }
        let standardizedExecutable = executableURL.standardizedFileURL
        let executableDirectory = standardizedExecutable.deletingLastPathComponent()
        let contentsDirectory = executableDirectory.deletingLastPathComponent()
        let isApplicationBundle = executableDirectory.lastPathComponent == "MacOS"
            && contentsDirectory.lastPathComponent == "Contents"
            && contentsDirectory.deletingLastPathComponent().pathExtension == "app"
        let resourceRoot = isApplicationBundle
            ? contentsDirectory.appendingPathComponent("Resources", isDirectory: true)
            : executableDirectory

        var missing: [String] = []
        if !isRunnableFile(standardizedExecutable) {
            missing.append(standardizedExecutable.lastPathComponent)
        }
        if isApplicationBundle {
            let infoPlist = contentsDirectory.appendingPathComponent("Info.plist")
            if !isValidApplicationInfoPlist(infoPlist) {
                missing.append("Contents/Info.plist")
            }
        }
        for base in resourceBundleBases {
            if PackageResourceBundle.locate(named: base,
                                            searchRoots: [resourceRoot]) == nil {
                missing.append("\(base).{bundle,resources}")
            }
        }
        guard missing.isEmpty else {
            throw PlayerInstallValidationError.missingComponents(missing.sorted())
        }
        return "GuavaPlayer installation validation passed ("
            + "\(resourceBundleBases.count) resource bundles)"
    }

    private static func isRunnableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        #if os(Windows)
        return true
        #else
        return FileManager.default.isExecutableFile(atPath: url.path)
        #endif
    }

    private static func isValidApplicationInfoPlist(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return false
        }
        return info["CFBundlePackageType"] as? String == "APPL"
            && !(info["CFBundleExecutable"] as? String ?? "").isEmpty
    }
}
