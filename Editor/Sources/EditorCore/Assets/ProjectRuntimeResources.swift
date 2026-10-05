import AudioRuntime
import AssetPipeline
import Foundation

/// Discovers project resources that are consumed directly at runtime rather than
/// imported into a render asset slot.
public enum ProjectRuntimeResources {
    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aiff", "aif", "caf", "ogg",
    ]
    private static let excludedDirectories: Set<String> = [
        ".git", ".guava", ".build", "build", "export", "node_modules", ".gradle",
    ]

    /// Registers the project root and every directory containing an audio clip.
    /// `AudioSource.clipName` is intentionally filename-based, so nested asset folders
    /// must be registered explicitly.
    @discardableResult
    public static func configureAudioSearchPaths(at rootPath: String) -> [URL] {
        let directories = discoverAudioSearchPaths(at: rootPath)
        AudioEngine.shared.setSearchURLs(directories)
        return directories
    }

    /// Pure discovery half of configuration, kept internal for deterministic
    /// tests without mutating the process-wide audio engine.
    static func discoverAudioSearchPaths(at rootPath: String) -> [URL] {
        let fileManager = FileManager.default
        let root = ProjectFilePath.canonicalURL(URL(fileURLWithPath: rootPath, isDirectory: true))
        var directories: [URL] = [root]
        var seen = Set([pathKey(root)])
        if let files = try? ProjectResourceWalker.files(in: root, fileManager: fileManager,
                                                       continueOnError: true,
                                                       excludingDirectory: {
            excludedDirectories.contains($0.lastPathComponent.lowercased())
        }) {
            for url in files {
                guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let directory = url.deletingLastPathComponent().standardizedFileURL
                if seen.insert(pathKey(directory)).inserted {
                    directories.append(directory)
                }
            }
        }
        return directories
    }

    private static func pathKey(_ url: URL) -> String {
        ProjectFilePath.comparableComponents(url).joined(separator: "/")
    }
}
