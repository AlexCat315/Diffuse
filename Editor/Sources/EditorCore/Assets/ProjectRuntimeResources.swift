import AudioRuntime
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
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        var directories: [URL] = [root]
        var seen = Set([pathKey(root)])
        let properties: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        if let enumerator = fileManager.enumerator(at: root,
                                                   includingPropertiesForKeys: properties,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(properties)) else { continue }
                if values.isDirectory == true {
                    if excludedDirectories.contains(url.lastPathComponent.lowercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let directory = url.deletingLastPathComponent().standardizedFileURL
                if seen.insert(pathKey(directory)).inserted {
                    directories.append(directory)
                }
            }
        }
        return directories
    }

    private static func pathKey(_ url: URL) -> String {
        #if os(Windows)
        return url.standardizedFileURL.path.lowercased()
        #else
        return url.standardizedFileURL.path
        #endif
    }
}
