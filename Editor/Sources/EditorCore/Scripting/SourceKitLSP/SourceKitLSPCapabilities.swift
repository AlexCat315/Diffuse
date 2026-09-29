import Foundation

/// Optional command-line flags supported by a particular `sourcekit-lsp` build.
///
/// Flags come and go between toolchain releases — `--bypass-workspace-trust`
/// arrived long after `--default-workspace-type`, for instance. Passing an
/// unknown flag aborts the process before a single message is exchanged, so the
/// client probes support instead of hard-coding a list.
public struct SourceKitLSPCapabilities: Sendable, Equatable {
    public let supportsDefaultWorkspaceType: Bool
    public let supportsScratchPath: Bool
    public let supportsBypassWorkspaceTrust: Bool

    public init(supportsDefaultWorkspaceType: Bool,
                supportsScratchPath: Bool,
                supportsBypassWorkspaceTrust: Bool) {
        self.supportsDefaultWorkspaceType = supportsDefaultWorkspaceType
        self.supportsScratchPath = supportsScratchPath
        self.supportsBypassWorkspaceTrust = supportsBypassWorkspaceTrust
    }

    /// Everything we currently know how to ask for, gated only by actual
    /// support — the probe could not run, so assume the modern set is present.
    public static let optimistic = SourceKitLSPCapabilities(supportsDefaultWorkspaceType: true,
                                                            supportsScratchPath: true,
                                                            supportsBypassWorkspaceTrust: true)
}

/// Turns capabilities into the argument list the client launches with.
public enum SourceKitLSPCommandLine {
    public static func arguments(for workspaceURL: URL,
                                 scratchURL: URL,
                                 capabilities: SourceKitLSPCapabilities) -> [String] {
        var arguments: [String] = []
        if capabilities.supportsDefaultWorkspaceType {
            arguments.append(contentsOf: ["--default-workspace-type", "swiftPM"])
        }
        if capabilities.supportsScratchPath {
            arguments.append(contentsOf: ["--scratch-path", scratchURL.path])
        }
        if capabilities.supportsBypassWorkspaceTrust {
            arguments.append("--bypass-workspace-trust")
        }
        return arguments
    }
}

extension SourceKitLSPExecutableLocator {
    /// Runs `<executable> --help` and parses which of our flags appear.
    ///
    /// `--help` exits immediately and costs a few milliseconds; doing it once
    /// per client lifetime is far cheaper than recovering from a dead process.
    /// Falling back to ``SourceKitLSPCapabilities/optimistic`` keeps behaviour
    /// unchanged when the probe itself cannot run (sandboxed launch, sandboxed
    /// output, etc.), which is the safer failure mode.
    public static func probeCapabilities(executableURL: URL) -> SourceKitLSPCapabilities {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--help"]
        process.standardOutput = output
        process.standardError = output

        do { try process.run() } catch { return .optimistic }

        // `--help` normally finishes instantly, but a toolchain wrapped in a
        // shim can block indefinitely — the failure mode of "help is slow"
        // must never hang the editor.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if process.isRunning {
            process.terminate()
            return .optimistic
        }

        let help = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard !help.isEmpty else { return .optimistic }
        return SourceKitLSPCapabilities(
            supportsDefaultWorkspaceType: help.contains("--default-workspace-type"),
            supportsScratchPath: help.contains("--scratch-path"),
            supportsBypassWorkspaceTrust: help.contains("--bypass-workspace-trust")
        )
    }
}
