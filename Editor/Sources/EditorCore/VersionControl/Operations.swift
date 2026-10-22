import Foundation

/// A version control backend whose every command comes from its plugin.
struct PluginBackend: VersionControlBackend {
    let repository: VersionControlRepository
    let plugin: StepPlugin

    func status() async throws -> VersionControlStatus {
        try await result(["op": "status"], as: StatusWire.self).model
    }

    func history(limit: Int) async throws -> [VersionControlRevision] {
        try await result(["op": "history", "limit": limit], as: [RevisionWire].self).map(\.model)
    }

    func branches() async throws -> [VersionControlBranch] {
        try await result(["op": "branches"], as: [BranchWire].self).map(\.model)
    }

    func diff(_ change: VersionControlChange) async throws -> String {
        switch try await plugin.perform(["op": "diff", "change": Self.wire(change)]) {
        case let .output(text): text
        case let .result(data): (try? JSONDecoder().decode(String.self, from: data)) ?? ""
        }
    }

    func stage(_ paths: [String]) async throws { try await perform(["op": "stage", "paths": paths]) }
    func unstage(_ paths: [String]) async throws { try await perform(["op": "unstage", "paths": paths]) }

    func discard(_ changes: [VersionControlChange]) async throws {
        try await perform(["op": "discard", "changes": changes.map(Self.wire)])
    }

    func commit(message: String, stageAll: Bool) async throws {
        try await perform(["op": "commit", "message": message, "stageAll": stageAll])
    }

    func pull() async throws { try await perform(["op": "pull"]) }
    func push() async throws { try await perform(["op": "push"]) }
    func switchBranch(_ name: String) async throws { try await perform(["op": "switch-branch", "name": name]) }
    func createBranch(_ name: String) async throws { try await perform(["op": "create-branch", "name": name]) }

    func locks() async throws -> Set<String> {
        Set(try await result(["op": "locks"], as: [String].self))
    }

    func setLocked(_ locked: Bool, paths: [String]) async throws {
        try await perform(["op": "set-locked", "locked": locked, "paths": paths])
    }

    private func perform(_ operation: [String: Any]) async throws {
        _ = try await plugin.perform(operation)
    }

    private func result<T: Decodable>(_ operation: [String: Any], as type: T.Type) async throws -> T {
        guard case let .result(data) = try await plugin.perform(operation) else {
            throw VersionControlError.unsupported("The \(plugin.provider.title) plugin returned text for \(operation["op"] ?? "").")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func wire(_ change: VersionControlChange) -> [String: Any] {
        var object: [String: Any] = ["path": change.path, "state": change.state.rawValue, "staged": change.isStaged]
        if let original = change.originalPath { object["originalPath"] = original }
        return object
    }
}

// The JSON plugins return, decoded into the editor's model.

struct StatusWire: Decodable {
    struct Change: Decodable {
        let path: String
        let originalPath: String?
        let state: VersionControlFileState
        let staged: Bool
    }
    let branch: String?
    let upstream: String?
    let ahead: Int
    let behind: Int
    let changes: [Change]

    var model: VersionControlStatus {
        VersionControlStatus(
            tracking: VersionControlTracking(branch: branch, upstream: upstream, ahead: ahead, behind: behind),
            changes: changes.map { VersionControlChange(path: $0.path, originalPath: $0.originalPath, state: $0.state, isStaged: $0.staged) })
    }
}

struct RevisionWire: Decodable {
    let id: String
    let summary: String
    let author: String?
    /// Seconds since 1970.
    let date: Int?

    var model: VersionControlRevision {
        VersionControlRevision(id: id, summary: summary, author: author,
                               date: date.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

struct BranchWire: Decodable {
    let name: String
    let current: Bool
    let remote: Bool

    var model: VersionControlBranch { VersionControlBranch(name: name, isCurrent: current, isRemote: remote) }
}
