import Foundation

/// One version control system's command set. Every path is repository-relative.
/// Backends run their tool out of process and never invoke a shell.
protocol VersionControlBackend: Sendable {
    var repository: VersionControlRepository { get }
    func status() async throws -> VersionControlStatus
    func history(limit: Int) async throws -> [VersionControlRevision]
    func branches() async throws -> [VersionControlBranch]
    /// A unified diff of one file against the last revision.
    func diff(_ change: VersionControlChange) async throws -> String
    func stage(_ paths: [String]) async throws
    func unstage(_ paths: [String]) async throws
    /// Restores files to the last revision; untracked files are removed.
    func discard(_ changes: [VersionControlChange]) async throws
    /// Commits the staged changes, staging everything first when nothing is.
    func commit(message: String, stageAll: Bool) async throws
    func pull() async throws
    func push() async throws
    func switchBranch(_ name: String) async throws
    func createBranch(_ name: String) async throws
    /// Paths locked by this user; systems without locks return nothing.
    func locks() async throws -> Set<String>
    func setLocked(_ locked: Bool, paths: [String]) async throws
}

public enum VersionControlError: Error, LocalizedError, Equatable, Sendable {
    case toolMissing(VersionControlSystem)
    case commandFailed(command: String, message: String)
    case unsupported(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case let .toolMissing(system):
            "The \(system.title) command-line tool was not found. Install it and make sure it is on PATH."
        case let .commandFailed(command, message):
            message.isEmpty ? "\(command) failed." : message
        case let .unsupported(message), let .invalidInput(message):
            message
        }
    }
}
