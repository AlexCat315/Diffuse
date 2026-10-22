import Foundation

/// Git through its machine-readable porcelain formats.
struct GitBackend: VersionControlBackend {
    let repository: VersionControlRepository
    let tool: VersionControlTool

    static func initialize(at directory: URL, tool: VersionControlTool) async throws {
        try await tool.run(["init", "--quiet"], in: directory)
    }

    func status() async throws -> VersionControlStatus {
        let output = try await git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        return Self.parseStatus(output.stdout)
    }

    func history(limit: Int) async throws -> [VersionControlRevision] {
        // A repository without commits has no log; that is not an error.
        let output = try await git(["log", "-n", "\(limit)", "--no-color", "--pretty=format:%H%x1f%an%x1f%at%x1f%s%x1e"],
                                   allowFailure: true)
        return output.status == 0 ? Self.parseLog(output.stdout) : []
    }

    func branches() async throws -> [VersionControlBranch] {
        let output = try await git(["for-each-ref", "--format=%(HEAD)%1f%(refname)", "refs/heads", "refs/remotes"])
        return Self.parseBranches(output.stdout)
    }

    func diff(_ change: VersionControlChange) async throws -> String {
        switch (change.state, change.isStaged) {
        case (.untracked, _):
            // `--no-index` exits 1 when the files differ, which they always do.
            return try await git(["diff", "--no-color", "--no-index", "--", "/dev/null", change.path], allowFailure: true).stdout
        case (_, true):
            return try await git(["diff", "--cached", "--no-color", "-M", "--"] + paths(of: change)).stdout
        default:
            return try await git(["diff", "--no-color", "--", change.path]).stdout
        }
    }

    func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await git(["add", "-A", "--"] + paths)
    }

    func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        // Before the first commit there is no HEAD to restore the index from.
        if try await git(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true).status == 0 {
            try await git(["restore", "--staged", "--"] + paths)
        } else {
            try await git(["rm", "--cached", "-r", "-q", "--"] + paths)
        }
    }

    func discard(_ changes: [VersionControlChange]) async throws {
        let created = changes.filter { $0.state == .untracked || $0.state == .added }
        let tracked = changes.filter { $0.state != .untracked && $0.state != .added }
        if !created.isEmpty {
            let staged = created.filter(\.isStaged).map(\.path)
            if !staged.isEmpty { try await git(["rm", "--cached", "-r", "-q", "--force", "--"] + staged) }
            try VersionControlFiles.trash(created.map(\.path), in: repository.root)
        }
        let paths = Array(Set(tracked.flatMap(paths(of:)))).sorted()
        guard !paths.isEmpty else { return }
        if tracked.contains(where: \.isStaged) {
            try await git(["restore", "--staged", "--worktree", "--source=HEAD", "--"] + paths)
        } else {
            try await git(["restore", "--worktree", "--"] + paths)
        }
    }

    func commit(message: String, stageAll: Bool) async throws {
        if stageAll { try await git(["add", "-A"]) }
        try await git(["commit", "--quiet", "--file=-"], input: message)
    }

    func pull() async throws {
        try await git(["pull", "--ff-only", "--quiet"], timeoutSeconds: 300)
    }

    func push() async throws {
        let status = try await status()
        if status.tracking.upstream == nil, let branch = status.tracking.branch {
            try await git(["push", "--quiet", "--set-upstream", "origin", branch], timeoutSeconds: 300)
        } else {
            try await git(["push", "--quiet"], timeoutSeconds: 300)
        }
    }

    func switchBranch(_ name: String) async throws {
        try Self.validateBranchName(name)
        try await git(["switch", "--quiet", name])
    }

    func createBranch(_ name: String) async throws {
        try Self.validateBranchName(name)
        try await git(["switch", "--quiet", "--create", name])
    }

    @discardableResult
    private func git(_ arguments: [String], input: String? = nil, timeoutSeconds: Int = 60,
                     allowFailure: Bool = false) async throws -> VersionControlTool.Result {
        try await tool.run(["-c", "core.quotepath=off", "-c", "color.ui=false"] + arguments, in: repository.root,
                           input: input, timeoutSeconds: timeoutSeconds, allowFailure: allowFailure)
    }

    private func paths(of change: VersionControlChange) -> [String] {
        [change.originalPath, change.path].compactMap { $0 }
    }

    static func validateBranchName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(".."),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: " ~^:?*[\\\0")) == nil else {
            throw VersionControlError.invalidInput("“\(name)” is not a valid branch name.")
        }
    }

    // MARK: Parsing

    /// Parses `git status --porcelain=v2 --branch -z`.
    static func parseStatus(_ output: String) -> VersionControlStatus {
        var status = VersionControlStatus()
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let record = fields.popFirst() {
            if record.hasPrefix("# ") {
                let parts = record.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head": status.tracking.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream": status.tracking.upstream = parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ")
                    status.tracking.ahead = counts.first.flatMap { Int($0.dropFirst()) } ?? 0
                    status.tracking.behind = counts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
                default: break
                }
                continue
            }
            guard let kind = record.first else { continue }
            switch kind {
            case "?":
                status.changes.append(VersionControlChange(path: String(record.dropFirst(2)), state: .untracked, isStaged: false))
            case "1", "2", "u":
                // Ordinary entries have 8 fields before the path, renames 9, unmerged 10.
                let prefixCount = kind == "1" ? 8 : kind == "2" ? 9 : 10
                let parts = record.split(separator: " ", maxSplits: prefixCount, omittingEmptySubsequences: false)
                guard parts.count == prefixCount + 1 else { continue }
                let path = String(parts[prefixCount])
                let codes = Array(parts[1])
                guard codes.count == 2 else { continue }
                let original = kind == "2" ? fields.popFirst() : nil
                if kind == "u" {
                    status.changes.append(VersionControlChange(path: path, state: .conflicted, isStaged: false))
                    continue
                }
                if let state = state(for: codes[0]) {
                    status.changes.append(VersionControlChange(path: path, originalPath: original, state: state, isStaged: true))
                }
                if let state = state(for: codes[1]) {
                    status.changes.append(VersionControlChange(path: path, state: state == .renamed ? .modified : state, isStaged: false))
                }
            default: continue
            }
        }
        return status
    }

    private static func state(for code: Character) -> VersionControlFileState? {
        switch code {
        case "M", "T": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "U": .conflicted
        default: nil
        }
    }

    static func parseLog(_ output: String) -> [VersionControlRevision] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty else { return nil }
            return VersionControlRevision(id: fields[0], summary: fields[3], author: fields[1],
                                          date: TimeInterval(fields[2]).map(Date.init(timeIntervalSince1970:)))
        }
    }

    static func parseBranches(_ output: String) -> [VersionControlBranch] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { return nil }
            let ref = fields[1]
            if ref.hasPrefix("refs/heads/") {
                return VersionControlBranch(name: String(ref.dropFirst("refs/heads/".count)), isCurrent: fields[0] == "*")
            }
            guard ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") else { return nil }
            return VersionControlBranch(name: String(ref.dropFirst("refs/remotes/".count)), isCurrent: false, isRemote: true)
        }
    }
}

/// Removing created files goes through the Trash so a discard can be undone.
enum VersionControlFiles {
    static func trash(_ paths: [String], in root: URL) throws {
        for path in paths {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw VersionControlError.invalidInput("Refusing to remove a path outside the repository: \(path)")
            }
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            #if os(macOS) || os(Windows)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            #else
            try FileManager.default.removeItem(at: url)
            #endif
        }
    }
}
