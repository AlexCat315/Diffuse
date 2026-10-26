private import CoveFileSystem
import Foundation
internal import EditorCore

/// Copies imported assets through a sibling staging file so re-importing never
/// deletes the last known-good project file before the replacement is ready.
enum AssetImportFileCopier {
    static func copyReplacing(source: URL,
                              destination: URL,
                              fileManager: FileManager = .default) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).import-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)

        if fileManager.fileExists(atPath: destination.path) {
            try FileReplacement.replace(destination, with: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}
