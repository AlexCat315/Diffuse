import Foundation
import ProcessRuntime

/// A located version control executable and the environment it runs with.
/// Commands run without a shell, never prompt, and are bounded in time and output.
struct VersionControlTool: Sendable {
    let executable: URL
    let environment: [String: String]

    /// GUI apps start with a minimal PATH, so the usual install locations are
    /// searched too: Homebrew, `~/.local/bin` (Lore's installer) and the system.
    static func locate(_ system: VersionControlSystem,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> VersionControlTool? {
        let name = system.rawValue
        let home = environment["HOME"] ?? NSHomeDirectory()
        let override = environment["GUAVA_\(name.uppercased())_EXECUTABLE"].map { [$0] } ?? []
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        let directories = (path + common).filter { seen.insert($0).inserted }
        let candidates = override + directories.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return VersionControlTool(executable: URL(fileURLWithPath: found),
                                  environment: runEnvironment(from: environment, searchPath: directories))
    }

    private static func runEnvironment(from environment: [String: String], searchPath: [String]) -> [String: String] {
        var result = environment.filter { key, _ in
            ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME",
             "GIT_CONFIG_GLOBAL", "LORE_IDENTITY_TOKEN", "LORE_ACCESS_TOKEN", "SystemRoot", "USERPROFILE"].contains(key)
        }
        result["PATH"] = searchPath.joined(separator: ":")
        // Never block on a credential or editor prompt nobody can answer.
        result["GIT_TERMINAL_PROMPT"] = "0"
        result["GIT_OPTIONAL_LOCKS"] = "0"
        result["GIT_EDITOR"] = "true"
        result["GCM_INTERACTIVE"] = "never"
        result["NO_COLOR"] = "1"
        return result
    }

    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    /// Runs the tool in `directory`. A non-zero exit throws with the tool's own
    /// message unless `allowFailure` is set.
    @discardableResult
    func run(_ arguments: [String], in directory: URL, input: String? = nil,
             timeoutSeconds: Int = 60, allowFailure: Bool = false) async throws -> Result {
        var command = ProcessCommand(executable: executable, directory: directory)
        command.arguments = arguments
        command.environment = environment
        var budget = ProcessBudget()
        budget.outputBytes = 16 * 1_048_576
        budget.lifetimeMilliseconds = timeoutSeconds * 1000
        let output = try await ProcessRunner.run(command, input: Data((input ?? "").utf8), budget: budget)
        let result = Result(stdout: String(decoding: output.stdout, as: UTF8.self),
                            stderr: String(decoding: output.stderr, as: UTF8.self),
                            status: output.status)
        if result.status != 0, !allowFailure {
            let message = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            throw VersionControlError.commandFailed(
                command: ([executable.lastPathComponent] + arguments.prefix(2)).joined(separator: " "),
                message: String(message.suffix(2000)))
        }
        return result
    }
}
