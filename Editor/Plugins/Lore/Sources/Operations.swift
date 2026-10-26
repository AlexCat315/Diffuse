import CovePluginKit

/// Resets files to the last revision; like Git, a discarded new file goes to the Trash.
func discard(_ request: StepRequest) -> Step {
    var paths: [String] = [], created: [String] = []
    for change in request["changes"]?.array ?? [] {
        guard let path = change["path"]?.string else { continue }
        paths.append(path)
        if change["state"]?.string == "added" || change["state"]?.string == "untracked" { created.append(path) }
    }
    if request.state == "trashed" { return .result(.null) }
    return batches(request, ["reset"], paths, then: created.isEmpty ? .result(.null) : .trash(created, next: "trashed"))
}

func commit(_ request: StepRequest) -> Step {
    if let output = request.output, !output.succeeded { return .failure(output.message) }
    switch request.state {
    case nil where request["stageAll"]?.bool == true:
        return .run(lore(["stage", "--scan", "."], timeout: 300), next: "commit")
    case nil, "commit"?:
        return .run(lore(["commit", request["message"]?.string ?? ""], timeout: 300), next: "done")
    default:
        return .result(.null)
    }
}

func switchBranch(_ request: StepRequest, create: Bool) -> Step {
    if let output = request.output, !output.succeeded { return .failure(output.message) }
    let name = request["name"]?.string ?? ""
    guard VersionControl.isValidBranchName(name) else { return .failure("“\(name)” is not a valid branch name.") }
    switch request.state {
    case nil where create: return .run(lore(["branch", "create", name]), next: "switch")
    case nil, "switch"?: return .run(lore(["branch", "switch", name], timeout: 600), next: "done")
    default: return .result(.null)
    }
}

/// Lore repositories live on a server: creating one registers it there and
/// turns the project directory into its working tree.
func initialize(_ request: StepRequest) -> Step {
    if request.output != nil { return finish(request) }
    let remote = request["remote"]?.string ?? ""
    guard remote.hasBytePrefix("lore://") || remote.hasBytePrefix("lores://") else {
        return .failure("Lore repositories are addressed as lore://host:port/name.")
    }
    return .run(lore(["repository", "create", remote], timeout: 120), next: "done")
}
