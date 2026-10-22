import Foundation

/// Editor extension points a package fills in. Each one names the host
/// feature it extends; an absent point contributes nothing.
public struct PluginContributions: Codable, Sendable, Equatable {
    public var versionControl: VersionControlContribution?
    public var tasks: TaskContribution?
    public var languages: [LanguageContribution]

    public init(versionControl: VersionControlContribution? = nil, tasks: TaskContribution? = nil,
                languages: [LanguageContribution] = []) {
        self.versionControl = versionControl
        self.tasks = tasks
        self.languages = languages
    }

    private enum CodingKeys: String, CodingKey { case versionControl, tasks, languages }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        versionControl = try values.decodeIfPresent(VersionControlContribution.self, forKey: .versionControl)
        tasks = try values.decodeIfPresent(TaskContribution.self, forKey: .tasks)
        languages = try values.decodeIfPresent([LanguageContribution].self, forKey: .languages) ?? []
    }
}

/// `record { request: string, stdout: string }`: the step request as JSON and
/// a window of the last command's output, the input of every entry point the
/// step protocol drives.
let stepInputType = WITValueType.record([WITRecordField(name: "request", type: .string),
                                         WITRecordField(name: "stdout", type: .string)])

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

/// A language the editor edits: the files that are written in it and, when
/// the package runs one, its language server. The server is a process
/// permission of the package; its traffic flows through the permission's
/// entry point.
public struct LanguageContribution: Codable, Sendable, Equatable {
    /// The LSP language identifier, such as `swift`.
    public var id: String
    public var title: String
    /// File name extensions without the dot.
    public var extensions: [String]
    public var server: LanguageServerContribution?

    public init(id: String, title: String, extensions: [String], server: LanguageServerContribution? = nil) {
        self.id = id
        self.title = title
        self.extensions = extensions
        self.server = server
    }
}

public struct LanguageServerContribution: Codable, Sendable, Equatable {
    /// The id of the process permission that starts the server.
    public var process: String
    /// Sent as `initializationOptions`; the editor may add host facts to it.
    public var initializationOptions: PluginJSON?
    /// Answers `workspace/configuration`, keyed by section.
    public var settings: PluginJSON?
    /// File names, beside the language's extensions, whose changes on disk the
    /// server is told about, such as a package manifest.
    public var watchedFiles: [String]?

    public init(process: String, initializationOptions: PluginJSON? = nil, settings: PluginJSON? = nil,
                watchedFiles: [String]? = nil) {
        self.process = process
        self.initializationOptions = initializationOptions
        self.settings = settings
        self.watchedFiles = watchedFiles
    }
}

extension PluginContributions {
    func validate(host: PluginHostPermissions) throws {
        let identifier = #"^[a-z][a-z0-9-]{0,31}$"#
        func isIdentifier(_ value: String) -> Bool { value.range(of: identifier, options: .regularExpression) != nil }
        func isTitle(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespaces).isEmpty && value.count <= 40 }
        func stepProcesses(_ entryPoint: String) -> Int { host.processes.filter { $0.entryPoints.contains(entryPoint) }.count }
        if let versionControl {
            guard isIdentifier(versionControl.id), isTitle(versionControl.title),
                  Self.isFileName(versionControl.marker), Self.isFileName(versionControl.ignoreFile),
                  host.processes.count == 1,
                  host.processes[0].entryPoints == [VersionControlContribution.entryPoint] else {
                throw PluginManifestValidationError.invalidContribution("versionControl")
            }
        }
        if let tasks {
            guard isIdentifier(tasks.id), isTitle(tasks.title), Self.isFileName(tasks.marker),
                  stepProcesses(TaskContribution.entryPoint) == 1 else {
                throw PluginManifestValidationError.invalidContribution("tasks")
            }
        }
        var seen = Set<String>()
        for language in languages {
            guard isIdentifier(language.id), seen.insert(language.id).inserted, isTitle(language.title),
                  !language.extensions.isEmpty,
                  language.extensions.allSatisfy({ $0.range(of: #"^[A-Za-z0-9_+-]{1,16}$"#, options: .regularExpression) != nil }),
                  language.server.map({ server in host.processes.contains { $0.id == server.process } }) ?? true else {
                throw PluginManifestValidationError.invalidContribution("languages")
            }
        }
    }

    /// The entry points the step protocol drives, which take ``stepInputType``.
    var stepEntryPoints: [(entryPoint: String, contribution: String)] {
        (versionControl == nil ? [] : [(VersionControlContribution.entryPoint, "versionControl")])
            + (tasks == nil ? [] : [(TaskContribution.entryPoint, "tasks")])
    }

    /// One path component: markers and ignore files live in the working tree root.
    private static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name != "." && name != ".."
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil
    }
}
