public import Foundation

/// Recoverable removal of workspace-relative files, including hidden project files.
public enum WorkspaceTrash {
    public static func remove(_ path: String, in root: URL) throws {
        let components = path.split(separator: "/")
        guard !components.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !components.contains(where: { $0 == "." || $0 == ".." }), components.first != ".guava" else {
            throw DocumentError.invalidPath
        }
        var source = root.standardizedFileURL
        for component in components {
            source.appendPathComponent(String(component))
            guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw DocumentError.invalidPath
            }
        }
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        #if os(macOS)
        try FileManager.default.trashItem(at: source, resultingItemURL: nil)
        #else
        var trash = root
        for component in [".guava", "trash"] {
            trash.appendPathComponent(component)
            guard (try? trash.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw DocumentError.invalidPath
            }
        }
        let destination = trash.appendingPathComponent(UUID().uuidString).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        #endif
    }
}
