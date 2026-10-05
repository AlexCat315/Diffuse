import Foundation
#if os(Windows)
import WinSDK
#endif

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
            #if os(Windows)
            // Foundation's replaceItemAt is unimplemented on Windows. A
            // sibling staging file can be replaced atomically with Win32.
            let errorCode = staging.path.withCString(encodedAs: UTF16.self) { sourcePath in
                destination.path.withCString(encodedAs: UTF16.self) { destinationPath in
                    let replaced = MoveFileExW(sourcePath, destinationPath,
                                               DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                    return replaced ? DWORD(0) : GetLastError()
                }
            }
            guard errorCode == 0 else {
                throw NSError(domain: "NSWin32ErrorDomain", code: Int(errorCode),
                              userInfo: [NSFilePathErrorKey: destination.path])
            }
            #else
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            #endif
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }
}
