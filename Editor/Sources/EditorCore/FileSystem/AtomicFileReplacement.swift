import Foundation
#if os(Windows)
private import WinSDK
#endif

/// Moves a fully written sibling file over an existing file.
package enum AtomicFileReplacement {
    package static func replace(_ destination: URL, with staging: URL) throws {
        #if os(Windows)
        // Foundation's replaceItemAt is unimplemented on Windows. MoveFileEx
        // replaces an existing sibling atomically.
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
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        #endif
    }
}
