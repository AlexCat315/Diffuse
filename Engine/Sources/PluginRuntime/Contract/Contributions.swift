import Foundation

/// Editor extension points a package fills in. Each one names the host
/// feature it extends; an absent point contributes nothing.
public struct PluginContributions: Codable, Sendable, Equatable {
    public var versionControl: VersionControlContribution?
    public init(versionControl: VersionControlContribution? = nil) { self.versionControl = versionControl }
}

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
    /// `record provider-input { request: string, stdout: string }`: the step
    /// request as JSON and a window of the last command's output.
    static let inputType = WITValueType.record([WITRecordField(name: "request", type: .string),
                                                WITRecordField(name: "stdout", type: .string)])

    public init(id: String, title: String, marker: String, ignoreFile: String, priority: Int? = nil) {
        self.id = id
        self.title = title
        self.marker = marker
        self.ignoreFile = ignoreFile
        self.priority = priority
    }
}

extension PluginContributions {
    func validate(host: PluginHostPermissions) throws {
        guard let versionControl else { return }
        let identifier = #"^[a-z][a-z0-9-]{0,31}$"#
        guard versionControl.id.range(of: identifier, options: .regularExpression) != nil,
              !versionControl.title.trimmingCharacters(in: .whitespaces).isEmpty, versionControl.title.count <= 40,
              Self.isFileName(versionControl.marker), Self.isFileName(versionControl.ignoreFile),
              host.processes.count == 1,
              host.processes[0].entryPoints == [VersionControlContribution.entryPoint] else {
            throw PluginManifestValidationError.invalidContribution("versionControl")
        }
    }

    /// One path component: markers and ignore files live in the working tree root.
    private static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name != "." && name != ".."
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0")) == nil
    }
}
