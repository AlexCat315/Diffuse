#if os(macOS) || os(Linux) || os(Windows)
import Foundation

public enum FFmpegTools {
    /// Installed workstations ship a pinned tool beside their executable.
    /// Source builds use the same tool staged by `cove-dev media`.
    public static func executable() throws -> URL {
        #if os(Windows)
        let name = "ffmpeg.exe"
        #else
        let name = "ffmpeg"
        #endif
        let directory = Bundle.main.executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
        var candidates = [directory.appendingPathComponent("Tools/\(name)"),
                          directory.deletingLastPathComponent().appendingPathComponent("Helpers/\(name)")]
        if let override = ProcessInfo.processInfo.environment["COVE_FFMPEG_EXECUTABLE"] {
            candidates.insert(URL(fileURLWithPath: override), at: 0)
        }
        #if os(macOS)
        #if arch(arm64)
        let variant = "macos-arm64"
        #else
        let variant = "macos-x86_64"
        #endif
        #elseif os(Windows)
        #if arch(arm64)
        let variant = "windows-arm64"
        #else
        let variant = "windows-x86_64"
        #endif
        #else
        #if arch(arm64)
        let variant = "linux-aarch64"
        #else
        let variant = "linux-x86_64"
        #endif
        #endif
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(package.appendingPathComponent("vendor/FFmpeg.artifactbundle/\(variant)/bin/\(name)"))
        guard let result = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MediaError.export("Pinned FFmpeg tool is missing. Run `cove-dev native-bootstrap` or configure COVE_FFMPEG_EXECUTABLE.")
        }
        return result
    }
}
#endif
