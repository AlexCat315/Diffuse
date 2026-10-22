import Foundation

/// Lore (https://github.com/EpicGames/lore) through its CLI. Reads use the
/// `--json` event stream (one `{"tagName", "data"}` object per line); history
/// uses `--oneline`, whose JSON form carries no messages.
struct LoreBackend: VersionControlBackend {
    let repository: VersionControlRepository
    let tool: VersionControlTool

    /// Lore repositories live on a server: creating one registers it there and
    /// turns `directory` into its working tree.
    static func create(at directory: URL, remote: String, tool: VersionControlTool) async throws {
        guard remote.hasPrefix("lore://") || remote.hasPrefix("lores://") else {
            throw VersionControlError.invalidInput("Lore repositories are addressed as lore://host:port/name.")
        }
        try await tool.run(["--non-interactive", "repository", "create", remote], in: directory, timeoutSeconds: 120)
    }

    func status() async throws -> VersionControlStatus {
        let output = try await lore(["--json", "status", "--scan"], timeoutSeconds: 120)
        return Self.parseStatus(output.stdout)
    }

    func history(limit: Int) async throws -> [VersionControlRevision] {
        let output = try await lore(["history", "\(limit)", "--oneline"], allowFailure: true)
        return output.status == 0 ? Self.parseHistory(output.stdout) : []
    }

    func branches() async throws -> [VersionControlBranch] {
        Self.parseBranches(try await lore(["--json", "branch", "list"], allowFailure: true).stdout)
    }

    func diff(_ change: VersionControlChange) async throws -> String {
        try await lore(["diff", change.path], allowFailure: true).stdout
    }

    func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await lore(["stage"] + paths)
    }

    func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await lore(["unstage"] + paths)
    }

    func discard(_ changes: [VersionControlChange]) async throws {
        guard !changes.isEmpty else { return }
        try await lore(["reset"] + changes.map(\.path))
        // Like Git, discarding a new file removes it, through the Trash.
        try VersionControlFiles.trash(changes.filter { $0.state == .added || $0.state == .untracked }.map(\.path),
                                      in: repository.root)
    }

    func commit(message: String, stageAll: Bool) async throws {
        if stageAll { try await lore(["stage", "--scan", "."], timeoutSeconds: 300) }
        try await lore(["commit", message], timeoutSeconds: 300)
    }

    func pull() async throws { try await lore(["sync"], timeoutSeconds: 600) }

    func push() async throws { try await lore(["push"], timeoutSeconds: 600) }

    func switchBranch(_ name: String) async throws {
        try GitBackend.validateBranchName(name)
        try await lore(["branch", "switch", name], timeoutSeconds: 600)
    }

    func createBranch(_ name: String) async throws {
        try GitBackend.validateBranchName(name)
        try await lore(["branch", "create", name])
        try await lore(["branch", "switch", name], timeoutSeconds: 600)
    }

    /// Locks live on the server; offline, the list is simply empty.
    func locks() async throws -> Set<String> {
        let output = try await lore(["--json", "lock", "status"], allowFailure: true)
        return output.status == 0 ? Self.parseLocks(output.stdout) : []
    }

    func setLocked(_ locked: Bool, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await lore(["lock", locked ? "acquire" : "release"] + paths)
    }

    @discardableResult
    private func lore(_ arguments: [String], timeoutSeconds: Int = 60,
                      allowFailure: Bool = false) async throws -> VersionControlTool.Result {
        try await tool.run(["--non-interactive", "--no-pager"] + arguments, in: repository.root,
                           timeoutSeconds: timeoutSeconds, allowFailure: allowFailure)
    }

    // MARK: Parsing

    private static func events(_ output: String) -> [(tag: String, data: [String: Any])] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let tag = object["tagName"] as? String else { return nil }
            return (tag, object["data"] as? [String: Any] ?? [:])
        }
    }

    /// Lore serializes some flags as booleans and others as 0/1 integers.
    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.intValue != 0
        default: false
        }
    }

    private static func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    static func parseStatus(_ output: String) -> VersionControlStatus {
        var status = VersionControlStatus()
        for event in events(output) {
            switch event.tag {
            case "repositoryStatusRevision":
                let data = event.data
                let branch = data["branchName"] as? String
                status.tracking.branch = branch?.isEmpty == false ? branch : nil
                if flag(data["remoteBranchExist"]) { status.tracking.upstream = status.tracking.branch }
                let local = number(data["revisionLocalNumber"]), remote = number(data["revisionRemoteNumber"])
                if flag(data["isLocalAhead"]) { status.tracking.ahead = max(1, local - remote) }
                if flag(data["isRemoteAhead"]) { status.tracking.behind = max(1, remote - local) }
            case "repositoryStatusFile":
                let data = event.data
                guard let path = data["path"] as? String, !path.isEmpty, data["type"] as? String != "directory" else { continue }
                let from = (data["fromPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let state: VersionControlFileState
                if flag(data["flagConflict"]) && flag(data["flagConflictUnresolved"]) {
                    state = .conflicted
                } else {
                    switch data["action"] as? String {
                    case "add": state = .added
                    case "delete": state = .deleted
                    case "move": state = .renamed
                    case "copy": state = .copied
                    default: state = .modified
                    }
                }
                status.changes.append(VersionControlChange(path: path, originalPath: from, state: state,
                                                           isStaged: flag(data["flagStaged"])))
            default: continue
            }
        }
        return status
    }

    /// `lore history --oneline` prints `<number> <first message line>`.
    static func parseHistory(_ output: String) -> [VersionControlRevision] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let number = parts.first, Int(number) != nil else { return nil }
            return VersionControlRevision(id: number, summary: parts.count > 1 ? parts[1] : "")
        }
    }

    static func parseBranches(_ output: String) -> [VersionControlBranch] {
        var seen = Set<String>()
        return events(output).compactMap { event in
            guard event.tag == "branchListEntry", let name = event.data["name"] as? String, !name.isEmpty else { return nil }
            let isRemote = event.data["location"] as? String == "remote"
            // A branch present locally and remotely is listed once.
            guard seen.insert(name).inserted else { return nil }
            return VersionControlBranch(name: name, isCurrent: flag(event.data["isCurrent"]), isRemote: isRemote)
        }
    }

    static func parseLocks(_ output: String) -> Set<String> {
        Set(events(output).compactMap { event in
            guard event.tag == "lockFileStatus" || event.tag == "lockFileQuery" else { return nil }
            return (event.data["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        })
    }
}
