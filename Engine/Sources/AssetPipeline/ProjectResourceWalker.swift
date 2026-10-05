import Foundation

/// Walks each directory independently so pruning one subtree never changes
/// whether later sibling directories are visited. Windows Foundation's
/// DirectoryEnumerator.skipDescendants() persists its shallow-walk option.
public enum ProjectResourceWalker {
    public static func files(in root: URL,
                             fileManager: FileManager = .default,
                             continueOnError: Bool = false,
                             excludingDirectory: (URL) -> Bool) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
                                       .isSymbolicLinkKey, .isPackageKey]
        var pending = [root]
        var files: [URL] = []
        while let directory = pending.popLast() {
            do {
                for url in try fileManager.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
                    do {
                        let values = try url.resourceValues(forKeys: keys)
                        guard values.isSymbolicLink != true else { continue }
                        if values.isDirectory == true {
                            if values.isPackage != true && !excludingDirectory(url) {
                                pending.append(url)
                            }
                        } else if values.isRegularFile == true {
                            files.append(url)
                        }
                    } catch {
                        if !continueOnError { throw error }
                    }
                }
            } catch {
                if !continueOnError { throw error }
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
