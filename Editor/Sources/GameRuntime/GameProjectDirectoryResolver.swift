import Foundation

/// Resolves the project consumed by GuavaPlayer in a deterministic priority order.
/// Besides explicit CLI/environment configuration, it recognizes both the macOS
/// app resource layout and the portable `Export/Player/GuavaPlayer` layout.
public enum GameProjectDirectoryResolver {
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                                       isDirectory: true)
    ) -> String? {
        if let index = arguments.firstIndex(of: "--project"),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            return arguments[index + 1]
        }
        if let environmentPath = environment["GUAVA_PROJECT_DIR"],
           !environmentPath.isEmpty {
            return environmentPath
        }
        if let bundleResourceURL {
            let bundledProject = bundleResourceURL.appendingPathComponent("GuavaProject",
                                                                          isDirectory: true)
            if isProjectDirectory(bundledProject) { return bundledProject.path }
        }
        let discoveredExecutableURL = executableURL ?? arguments.first.flatMap { argument in
            guard !argument.isEmpty else { return nil }
            return URL(fileURLWithPath: argument).standardizedFileURL
        }
        if let executableURL = discoveredExecutableURL {
            let executableDirectory = executableURL.deletingLastPathComponent()
            // Portable exports keep the executable under `<project>/Player/`.
            let portableProject = executableDirectory.deletingLastPathComponent()
            if isProjectDirectory(portableProject) { return portableProject.path }
            if isProjectDirectory(executableDirectory) { return executableDirectory.path }
        }
        return isProjectDirectory(currentDirectoryURL) ? currentDirectoryURL.path : nil
    }

    private static func isProjectDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("build.json", isDirectory: false).path
        )
    }
}
