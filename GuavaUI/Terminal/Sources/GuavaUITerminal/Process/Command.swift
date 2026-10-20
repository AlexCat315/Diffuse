public import Foundation

/// The program a `TerminalSession` runs on its pseudo terminal.
public struct TerminalCommand: Sendable, Equatable {
    /// Absolute path, or a name resolved through `PATH`.
    public var executable: String
    public var arguments: [String] = []
    /// Entries layered over the inherited environment. `TERM` and
    /// `COLORTERM` describe the emulator and are set unless overridden here.
    public var environment: [String: String] = [:]
    /// `nil` inherits the host process's working directory.
    public var workingDirectory: URL?

    public init(executable: String, arguments: [String] = [], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// The user's login shell (`$SHELL -l`), falling back to `/bin/sh`.
    public static var loginShell: TerminalCommand {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/sh"
        return TerminalCommand(executable: shell, arguments: ["-l"])
    }
}

extension TerminalCommand {
    /// Environment handed to the child: inherited, emulator identity, overrides.
    func resolvedEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = inherited
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        result["TERM_PROGRAM"] = "GuavaUI"
        if result["LANG"] == nil, result["LC_ALL"] == nil, result["LC_CTYPE"] == nil {
            result["LANG"] = "en_US.UTF-8"
        }
        result.merge(environment) { _, override in override }
        return result
    }

    /// Absolute executable path; names without a slash are looked up in `PATH`.
    func resolvedExecutable(path: String?) -> String? {
        let manager = FileManager.default
        if executable.contains("/") {
            return manager.isExecutableFile(atPath: executable) ? executable : nil
        }
        for directory in (path ?? "/usr/bin:/bin").split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
