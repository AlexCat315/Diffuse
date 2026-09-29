import Foundation

/// Locates a usable `sourcekit-lsp` executable on the host.
///
/// Resolution order mirrors what an editor extension does: an explicit
/// operator override first, then `PATH`, then whatever toolchain `xcrun`
/// currently points at. Keeping this outside ``SourceKitLSPClient`` lets the
/// lookup be exercised without spawning a process.
public enum SourceKitLSPExecutableLocator {
    public static let overrideEnvironmentKey = "GUAVA_SOURCEKIT_LSP_PATH"

    public static func resolveExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw SourceKitLSPClientError.executableNotFound(override)
            }
            return url
        }

        if let pathURL = executable(named: "sourcekit-lsp", path: environment["PATH"] ?? "") {
            return pathURL
        }

        if let xcrunURL = executable(named: "xcrun", path: environment["PATH"] ?? "") {
            if let found = try? resolveViaXcrun(xcrunURL), FileManager.default.isExecutableFile(atPath: found.path) {
                return found
            }
        }

        throw SourceKitLSPClientError.executableNotFound("sourcekit-lsp")
    }

    private static func resolveViaXcrun(_ xcrunURL: URL) throws -> URL {
        let process = Process()
        let output = Pipe()
        process.executableURL = xcrunURL
        process.arguments = ["--find", "sourcekit-lsp"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw SourceKitLSPClientError.executableNotFound("sourcekit-lsp")
        }
        process.waitUntilExit()
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !path.isEmpty else {
            throw SourceKitLSPClientError.executableNotFound("sourcekit-lsp")
        }
        return URL(fileURLWithPath: path)
    }

    private static func executable(named name: String, path: String) -> URL? {
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let base = directory.isEmpty ? "/usr/bin" : String(directory)
            let candidate = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
