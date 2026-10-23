/// A version control system driven through the package's `provider` entry
/// point. The plugin decides every command; the host runs it under the
/// package's process permission and feeds the output back.
public struct VersionControlContribution: Codable, Sendable, Equatable {
    /// The system's identifier, such as `git`.
    public var id: String
    public var title: String
    /// The file or directory that marks a working tree's root, such as `.git`.
    public var marker: String
    /// The ignore file initialization extends, such as `.gitignore`.
    public var ignoreFile: String
    /// Breaks ties when one folder holds several systems' markers; higher wins.
    public var priority: Int?

    /// The capability every version control package exports.
    public static let entryPoint = "provider"

    public init(id: String, title: String, marker: String, ignoreFile: String, priority: Int? = nil) {
        self.id = id
        self.title = title
        self.marker = marker
        self.ignoreFile = ignoreFile
        self.priority = priority
    }
}

/// Builds, tests and runs one kind of project through the package's `tasks`
/// entry point. The plugin decides each command and reads its output into
/// problems, tests and the project's description; the host runs the commands,
/// shows their output as it arrives and lists what the plugin read.
public struct TaskContribution: Codable, Sendable, Equatable {
    /// The project kind's identifier, such as `swiftpm`.
    public var id: String
    public var title: String
    /// The file in the project folder that marks such a project, such as `Package.swift`.
    public var marker: String

    public static let entryPoint = "tasks"

    public init(id: String, title: String, marker: String) {
        self.id = id
        self.title = title
        self.marker = marker
    }
}

