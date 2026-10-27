import Foundation

/// The version control systems the editor can drive, each through a bundled
/// plugin. Git suits code and text; Lore (Epic Games) adds a server-backed
/// store and file locks for large binary assets.
public struct VersionControlSystem: RawRepresentable, Codable, Sendable, CaseIterable, Hashable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard rawValue.range(of: #"^[a-z][a-z0-9-]{0,31}$"#, options: .regularExpression) != nil else { return nil }
        self.rawValue = rawValue
    }
    public static let git = VersionControlSystem(rawValue: "git")!
    public static let lore = VersionControlSystem(rawValue: "lore")!
    public static var allCases: [VersionControlSystem] { VersionControlProvider.bundled.map(\.system) }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid VCS identifier") }
        self = value
    }
    public func encode(to encoder: Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(rawValue) }

    /// The display name its plugin contributes.
    public var title: String { VersionControlProvider.provider(for: self)?.contribution.title ?? rawValue }
}

/// What happened to a file relative to the last revision.
public enum VersionControlFileState: String, Codable, Sendable, Hashable {
    case modified, added, deleted, renamed, copied, untracked, conflicted

    /// The one-letter badge used in file trees and change lists.
    public var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "U"
        case .conflicted: "!"
        }
    }
}

/// One changed path. A file with both staged and unstaged edits appears twice,
/// once per area, as in Git's index model; Lore reports one entry per file.
public struct VersionControlChange: Equatable, Sendable, Hashable, Identifiable {
    /// Repository-relative path using `/` separators.
    public let path: String
    /// The previous path of a rename or copy.
    public let originalPath: String?
    public let state: VersionControlFileState
    public let isStaged: Bool

    public var id: String { (isStaged ? "staged:" : "work:") + path }

    public init(path: String, originalPath: String? = nil, state: VersionControlFileState, isStaged: Bool) {
        self.path = path
        self.originalPath = originalPath
        self.state = state
        self.isStaged = isStaged
    }
}

/// One entry of the history list.
public struct VersionControlRevision: Equatable, Sendable, Hashable, Identifiable {
    /// A Git hash or a Lore revision number.
    public let id: String
    public let summary: String
    public let author: String?
    public let date: Date?

    public init(id: String, summary: String, author: String? = nil, date: Date? = nil) {
        self.id = id
        self.summary = summary
        self.author = author
        self.date = date
    }
}

public struct VersionControlBranch: Equatable, Sendable, Hashable, Identifiable {
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public var id: String { (isRemote ? "remote:" : "local:") + name }

    public init(name: String, isCurrent: Bool, isRemote: Bool = false) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
    }
}

/// Where the working tree stands relative to its upstream.
public struct VersionControlTracking: Equatable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public init(branch: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }
}

/// The result of reading a working tree once.
public struct VersionControlStatus: Equatable, Sendable {
    public var tracking = VersionControlTracking()
    public var changes: [VersionControlChange] = []
    public init(tracking: VersionControlTracking = .init(), changes: [VersionControlChange] = []) {
        self.tracking = tracking
        self.changes = changes
    }
}

/// A repository the editor has found for the project.
public struct VersionControlRepository: Equatable, Sendable {
    public let system: VersionControlSystem
    /// The working tree root; may be an ancestor of the project directory.
    public let root: URL
    public init(system: VersionControlSystem, root: URL) {
        self.system = system
        self.root = root
    }
}

/// Long-running operations a user can start from the Source Control panel.
public enum VersionControlOperation: String, Sendable, Equatable {
    case staging, unstaging, discarding, committing, pulling, pushing,
         switchingBranch, creatingBranch, initializing, locking
}

/// Everything views show about version control, compared as one value.
public struct VersionControlSnapshot: Equatable, Sendable {
    public enum Availability: Equatable, Sendable {
        /// Detection has not finished yet.
        case unknown
        /// The project is not inside a working tree.
        case noRepository
        /// A working tree exists but its command-line tool was not found.
        case toolMissing(VersionControlSystem)
        case ready(VersionControlRepository)
    }

    public var availability: Availability = .unknown
    public var status = VersionControlStatus()
    public var history: [VersionControlRevision] = []
    public var branches: [VersionControlBranch] = []
    /// Lore file locks held in this working tree, as repository paths.
    public var locks: Set<String> = []
    public var operation: VersionControlOperation?
    public var error: String?
    /// Tools found on this machine, for the empty state's init actions.
    public var installedSystems: Set<VersionControlSystem> = []
    /// Systems switched off in Settings; detection skips them.
    public var disabledSystems: Set<VersionControlSystem> = []
    /// The change in the editor's diff tab.
    public var comparison: VersionControlComparison?
    public init() {}

    public var repository: VersionControlRepository? {
        if case let .ready(repository) = availability { return repository }
        return nil
    }

    public var staged: [VersionControlChange] { status.changes.filter(\.isStaged) }
    public var unstaged: [VersionControlChange] { status.changes.filter { !$0.isStaged } }
}

/// A change shown in the editor's diff tab. It follows the file between the
/// staged and unstaged areas, and its diff is re-read after every refresh.
public struct VersionControlComparison: Equatable, Sendable {
    public var change: VersionControlChange
    /// Nil while the diff loads.
    public var diff: String?
    /// False once the file has no change left, e.g. after a commit.
    public var isCurrent = true
}
