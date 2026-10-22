import GuavaPluginKit

func stage(_ request: VersionControlRequest) -> VersionControlStep {
    if request.output != nil { return finish(request) }
    let paths = strings(request["paths"])
    return paths.isEmpty ? .result(.null) : .run(pathspecs(["add", "-A"], paths), next: "done")
}

func unstage(_ request: VersionControlRequest) -> VersionControlStep {
    let paths = strings(request["paths"])
    switch request.state {
    case nil:
        return paths.isEmpty ? .result(.null) : .run(git(["rev-parse", "--verify", "--quiet", "HEAD"]), next: "unstage")
    case "unstage"?:
        // Before the first commit there is no HEAD to restore the index from.
        let hasHead = request.output?.succeeded == true
        return .run(pathspecs(hasHead ? ["restore", "--staged"] : ["rm", "--cached", "-r", "-q"], paths), next: "done")
    default:
        return finish(request)
    }
}

/// Restores tracked files to the last revision. Created files leave the
/// index, then go to the Trash so the discard can be undone.
func discard(_ request: VersionControlRequest) -> VersionControlStep {
    var created: [Change] = [], tracked: [Change] = []
    for value in request["changes"]?.array ?? [] {
        guard let change = Change(value) else { continue }
        if change.state == "untracked" || change.state == "added" { created.append(change) } else { tracked.append(change) }
    }
    if let output = request.output, !output.succeeded { return .failure(output.message) }
    switch request.state {
    case nil:
        let staged = created.filter { $0.isStaged }.map { $0.path }
        if !staged.isEmpty { return .run(pathspecs(["rm", "--cached", "-r", "-q", "--force"], staged), next: "trash") }
        fallthrough
    case "trash"?:
        if !created.isEmpty { return .trash(created.map { $0.path }, next: "restore") }
        fallthrough
    case "restore"?:
        var paths: [String] = []
        for change in tracked {
            if let original = change.originalPath { paths.append(original) }
            paths.append(change.path)
        }
        paths = uniqueSorted(paths)
        guard !paths.isEmpty else { return .result(.null) }
        let arguments = tracked.contains { $0.isStaged }
            ? ["restore", "--staged", "--worktree", "--source=HEAD"] : ["restore", "--worktree"]
        return .run(pathspecs(arguments, paths), next: "done")
    default:
        return .result(.null)
    }
}

/// Commits the staged changes, staging everything first when asked.
func commit(_ request: VersionControlRequest) -> VersionControlStep {
    if let output = request.output, !output.succeeded { return .failure(output.message) }
    switch request.state {
    case nil where request["stageAll"]?.bool == true:
        return .run(git(["add", "-A"]), next: "commit")
    case nil, "commit"?:
        return .run(git(["commit", "--quiet", "--file=-"], input: request["message"]?.string ?? ""), next: "done")
    default:
        return .result(.null)
    }
}

struct Change {
    let path: String
    let originalPath: String?
    let state: String
    let isStaged: Bool

    init?(_ value: JSON) {
        guard let path = value["path"]?.string, let state = value["state"]?.string else { return nil }
        self.path = path
        originalPath = value["originalPath"]?.string
        self.state = state
        isStaged = value["staged"]?.bool ?? false
    }
}

private func uniqueSorted(_ values: [String]) -> [String] {
    var result: [String] = []
    for value in values.sorted() where result.last != value { result.append(value) }
    return result
}
