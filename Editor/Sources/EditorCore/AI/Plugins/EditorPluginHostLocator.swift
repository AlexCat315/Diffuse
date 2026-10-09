import Foundation

/// Resolves the PluginHost from locations controlled by the Editor build.
///
/// Plugin packages, AI output, project settings, and environment variables are
/// deliberately not consulted. Tests and embedding applications may inject a
/// path through `EditorApplication.init`; that call site is part of the trusted
/// host boundary, not plugin-controlled data.
public enum EditorPluginHostLocator {
    public static var executableName: String {
        #if os(Windows)
        "GuavaPluginHost.exe"
        #else
        "GuavaPluginHost"
        #endif
    }

    public static func resolve(injectedURL: URL? = nil,
                               bundle: Bundle = .main) -> URL? {
        if let injectedURL {
            return validatedExecutable(at: injectedURL)
        }

        let name = executableName
        var candidates: [URL] = []

        // Signed macOS application layout.
        candidates.append(bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false))

        // Release archives place trusted helper executables in Tools. A
        // same-directory candidate also supports local SwiftPM deployments.
        if let executableDirectory = bundle.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory
                .appendingPathComponent("Tools", isDirectory: true)
                .appendingPathComponent(name, isDirectory: false))
            candidates.append(executableDirectory
                .appendingPathComponent(name, isDirectory: false))
        }

        #if DEBUG
        // Source-tree fallback for developer builds. This is compiler-owned
        // location data, never a project or plugin-supplied path.
        var repositoryRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        for _ in 0..<4 {
            repositoryRoot.deleteLastPathComponent()
        }
        candidates.append(repositoryRoot
            .appendingPathComponent("Engine", isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false))
        #endif

        for candidate in candidates {
            if let resolved = validatedExecutable(at: candidate) {
                return resolved
            }
        }
        return nil
    }

    private static func validatedExecutable(at url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let sourceValues = try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard sourceValues?.isSymbolicLink != true else { return nil }
        let resolved = standardized.resolvingSymlinksInPath()
        let values = try? resolved.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              FileManager.default.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }
}
