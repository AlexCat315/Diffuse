import Foundation
private import GuavaProcess

/// A located command-line tool for a contribution and the environment it may run with.
struct ContributionTool: Sendable {
    let executable: URL
    let environment: [String: String]

    /// GUI apps start with a minimal PATH, so the usual install locations are
    /// searched too: Homebrew, `~/.local/bin` (Lore's installer) and the system.
    /// `GUAVA_<COMMAND>_EXECUTABLE` names a specific build.
    static func locate(_ command: String,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> ContributionTool? {
        #if os(Windows)
        let separator: Character = ";"
        let home = ProcessEnvironment.value("USERPROFILE", in: environment) ?? NSHomeDirectory()
        let common = ["\(home)/.cargo/bin", "\(home)/.local/bin"]
        #else
        let separator: Character = ":"
        let home = environment["HOME"] ?? NSHomeDirectory()
        let common = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin", "/usr/bin", "/bin"]
        #endif
        let path = (ProcessEnvironment.value("PATH", in: environment) ?? "").split(separator: separator).map(String.init)
        var seen = Set<String>()
        let directories = (path + common).filter { seen.insert($0).inserted }
        let inherited = ProcessEnvironment.setting(directories.joined(separator: String(separator)), for: "PATH", in: environment)
        let override = ProcessEnvironment.value("GUAVA_\(command.uppercased())_EXECUTABLE", in: environment)
        guard let executable = ToolLocator.executable(override ?? command, environment: inherited) else { return nil }
        return ContributionTool(executable: executable, environment: inherited)

    }

    /// The editor's values for the variables a plugin's process permission
    /// allows; PATH is the search path the tool was found on.
    func environment(allowing keys: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in ProcessEnvironment.value(key, in: environment).map { (key, $0) } })
    }
}
