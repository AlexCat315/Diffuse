import Foundation
import ScriptRuntime

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

        if let pathURL = try? SwiftScriptCompiler.resolveExecutableURL(for: "sourcekit-lsp", environment: environment) {
            return pathURL
        }

        #if os(macOS)
        if let xcrunURL = try? SwiftScriptCompiler.resolveExecutableURL(for: "xcrun", environment: environment) {
            if let found = try? resolveViaXcrun(xcrunURL), FileManager.default.isExecutableFile(atPath: found.path) {
                return found
            }
        }
        #endif

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

}
