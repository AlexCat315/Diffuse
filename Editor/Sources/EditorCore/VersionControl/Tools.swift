import Foundation

extension EditorApplication {
    /// The `vcs_*` project tools, over the same model the Source Control panel shows.
    @MainActor
    func executeVersionControlTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any]? {
        guard name.hasPrefix("vcs_") else { return nil }
        let versionControl = workstation.versionControl
        await versionControl.refresh()
        let snapshot = versionControl.snapshot
        guard let repository = snapshot.repository else {
            if case let .toolMissing(system) = snapshot.availability { throw VersionControlError.toolMissing(system) }
            throw EditorProjectToolError("This project is not in a Git or Lore working tree.")
        }
        switch name {
        case "vcs_status":
            let tracking = snapshot.status.tracking
            return ["system": repository.system.rawValue, "branch": tracking.branch ?? NSNull(),
                    "upstream": tracking.upstream ?? NSNull(), "ahead": tracking.ahead, "behind": tracking.behind,
                    "changes": snapshot.status.changes.map { change -> [String: Any] in
                        ["path": change.path, "state": change.state.rawValue, "staged": change.isStaged,
                         "original_path": change.originalPath ?? NSNull()]
                    }]
        case "vcs_diff":
            let path = arguments["path"] as? String
            let changes = snapshot.status.changes.filter { path == nil || $0.path == path }
            guard !changes.isEmpty else {
                throw EditorProjectToolError(path.map { "No change at \($0). Read vcs_status for changed paths." } ?? "There are no changes.")
            }
            var budget = 60_000
            var diffs: [[String: Any]] = []
            for change in changes {
                guard budget > 0 else { diffs.append(["path": change.path, "truncated": true]); continue }
                let diff = String(await versionControl.diff(change).prefix(budget))
                budget -= diff.count
                diffs.append(["path": change.path, "staged": change.isStaged, "diff": diff])
            }
            return ["diffs": diffs]
        case "vcs_log":
            let limit = arguments["limit"] as? Int ?? 20
            return ["revisions": snapshot.history.prefix(limit).map { revision -> [String: Any] in
                ["id": revision.id, "summary": revision.summary, "author": revision.author ?? NSNull(),
                 "date": revision.date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()]
            }]
        case "vcs_commit":
            let paths = Set(arguments["paths"] as? [String] ?? [])
            if let unknown = paths.subtracting(snapshot.status.changes.map(\.path)).first {
                throw EditorProjectToolError("\(unknown) has no change. Read vcs_status for changed paths.")
            }
            if !paths.isEmpty {
                await versionControl.stage(snapshot.unstaged.filter { paths.contains($0.path) })
                if let error = versionControl.snapshot.error { throw EditorProjectToolError(error) }
            }
            return try await commit(arguments["message"] as? String ?? "")
        default:
            return nil
        }
    }

    @MainActor
    private func commit(_ message: String) async throws -> [String: Any] {
        let versionControl = workstation.versionControl
        guard await versionControl.commit(message: message) else {
            throw EditorProjectToolError(versionControl.snapshot.error ?? "Commit failed.")
        }
        return ["ok": true, "revision": versionControl.snapshot.history.first?.id ?? NSNull()]
    }
}
