import Foundation
import EngineKernel

enum EditorInstallValidationError: Error, Equatable, CustomStringConvertible {
    case executableLocationUnavailable
    case missingComponents([String])

    var description: String {
        switch self {
        case .executableLocationUnavailable:
            return "Editor installation validation could not locate the executable."
        case let .missingComponents(components):
            return "Editor installation is incomplete; missing: \(components.joined(separator: ", "))"
        }
    }
}

enum EditorInstallValidator {
    private static let resourceBundleBases = [
        "GuavaEditor_EditorApp",
        "GuavaEditor_EditorCore",
        "GuavaEngine_RenderBackend",
        "GuavaUI_GuavaUIApp",
        "GuavaUI_GuavaUICompose",
        "GuavaUI_GuavaUIWorkspace",
    ]

    static func validateEditorLayout(
        executableURL: URL? = nil,
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        arguments: [String] = CommandLine.arguments,
        isWindows: Bool = {
            #if os(Windows)
            true
            #else
            false
            #endif
        }()
    ) throws -> String {
        guard let executableURL = executableURL
            ?? bundleExecutableURL
            ?? arguments.first.map({ URL(fileURLWithPath: $0) }) else {
            throw EditorInstallValidationError.executableLocationUnavailable
        }
        let standardizedExecutable = executableURL.standardizedFileURL
        let executableDirectory = standardizedExecutable.deletingLastPathComponent()
        let suffix = isWindows ? ".exe" : ""
        let contentsDirectory = executableDirectory.deletingLastPathComponent()
        let isApplicationBundle = !isWindows
            && executableDirectory.lastPathComponent == "MacOS"
            && contentsDirectory.lastPathComponent == "Contents"
            && contentsDirectory.deletingLastPathComponent().pathExtension == "app"
        let resourceRoot = isApplicationBundle
            ? contentsDirectory.appendingPathComponent("Resources", isDirectory: true)
            : executableDirectory
        let requiredFiles: [(label: String, url: URL, mustBeExecutable: Bool)] = isApplicationBundle
            ? [
                ("Contents/MacOS/EditorApp", standardizedExecutable, true),
                ("Contents/MacOS/GuavaPlayer",
                 executableDirectory.appendingPathComponent("GuavaPlayer"), true),
                ("Contents/Helpers/GuavaPluginHost",
                 contentsDirectory.appendingPathComponent("Helpers/GuavaPluginHost"), true),
                ("Contents/Helpers/GuavaMCP",
                 contentsDirectory.appendingPathComponent("Helpers/GuavaMCP"), true),
                ("Contents/Helpers/libwasmtime.dylib",
                 contentsDirectory.appendingPathComponent("Helpers/libwasmtime.dylib"), false),
            ]
            : [
                ("EditorApp\(suffix)",
                 executableDirectory.appendingPathComponent("EditorApp\(suffix)"), true),
                ("GuavaPlayer\(suffix)",
                 executableDirectory.appendingPathComponent("GuavaPlayer\(suffix)"), true),
                ("Tools/GuavaPluginHost\(suffix)",
                 executableDirectory.appendingPathComponent("Tools/GuavaPluginHost\(suffix)"), true),
                ("Tools/GuavaMCP\(suffix)",
                 executableDirectory.appendingPathComponent("Tools/GuavaMCP\(suffix)"), true),
            ]
        var missing = requiredFiles.compactMap { component in
            let isValid = component.mustBeExecutable
                ? isRunnableFile(component.url, isWindows: isWindows)
                : isRegularFile(component.url)
            return isValid ? nil : component.label
        }
        if isApplicationBundle {
            let infoPlist = contentsDirectory.appendingPathComponent("Info.plist")
            if !isValidApplicationInfoPlist(infoPlist,
                                            expectedExecutable: "EditorApp") {
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
            throw EditorInstallValidationError.missingComponents(missing.sorted())
        }
        let executableCount = requiredFiles.lazy.filter(\.mustBeExecutable).count
        return "Editor installation validation passed (\(executableCount) executables, "
            + "\(resourceBundleBases.count) resource bundles)"
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func isRunnableFile(_ url: URL, isWindows: Bool) -> Bool {
        guard isRegularFile(url) else { return false }
        return isWindows || FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func isValidApplicationInfoPlist(_ url: URL,
                                                    expectedExecutable: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return false
        }
        return info["CFBundleExecutable"] as? String == expectedExecutable
            && info["CFBundlePackageType"] as? String == "APPL"
    }
}
