import Foundation

/// A located version control executable and the environment it may run with.
struct VersionControlTool: Sendable {
    let executable: URL
    let environment: [String: String]

    /// GUI apps start with a minimal PATH, so the usual install locations are
    /// searched too: Homebrew, `~/.local/bin` (Lore's installer) and the system.
    /// `GUAVA_<COMMAND>_EXECUTABLE` names a specific build.
    static func locate(_ command: String,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> VersionControlTool? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let override = environment["GUAVA_\(command.uppercased())_EXECUTABLE"].map { [$0] } ?? []
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        let directories = (path + common).filter { seen.insert($0).inserted }
        let candidates = override + directories.map { URL(fileURLWithPath: $0).appendingPathComponent(command).path }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        var inherited = environment
        inherited["PATH"] = directories.joined(separator: ":")
        return VersionControlTool(executable: URL(fileURLWithPath: found), environment: inherited)
    }

    /// The editor's values for the variables a plugin's process permission
    /// allows; PATH is the search path the tool was found on.
    func environment(allowing keys: [String]) -> [String: String] {
        environment.filter { keys.contains($0.key) }
    }
}
