internal import GuavaProcess
import LanguageServerRuntime
import Foundation
import ScriptRuntime

/// Locates a usable `sourcekit-lsp` executable on the host.
///
/// Resolution order mirrors what an editor extension does: an explicit
/// operator override first, then `PATH`, then whatever toolchain `xcrun`
/// currently points at. Keeping this outside ``LSPClient`` lets the
/// lookup be exercised without spawning a process.
public enum SourceKitLSPExecutableLocator {
    public static let overrideEnvironmentKey = "GUAVA_SOURCEKIT_LSP_PATH"

    public static func resolveExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            guard let url = try? SwiftScriptCompiler.resolveExecutableURL(for: override, environment: environment) else {
                throw LSPClientError.executableNotFound(override)
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

        throw LSPClientError.executableNotFound("sourcekit-lsp")
    }

    private static func resolveViaXcrun(_ xcrunURL: URL) throws -> URL {
        var command = ProcessCommand(executable: xcrunURL, directory: FileManager.default.temporaryDirectory)
        command.arguments = ["--find", "sourcekit-lsp"]
        var budget = ProcessBudget(); budget.lifetimeMilliseconds = 5000; budget.outputBytes = 16_384
        guard let result = try? ProcessRunner.runSynchronously(command, budget: budget), result.status == 0 else {
            throw LSPClientError.executableNotFound("sourcekit-lsp")
        }
        let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw LSPClientError.executableNotFound("sourcekit-lsp") }
        return URL(fileURLWithPath: path)
    }

}
