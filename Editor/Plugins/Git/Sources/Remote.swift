import GuavaPluginKit

/// Pushes the current branch, publishing it to `origin` when it has no upstream yet.
func push(_ request: StepRequest) -> Step {
    switch request.state {
    case nil:
        return .run(git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=no"]), next: "push")
    case "push"?:
        guard let output = request.output, output.succeeded else { return .failure(request.output?.message ?? "") }
        let status = tracking(of: output.stdout)
        if status.upstream == nil, let branch = status.branch {
            return .run(git(["push", "--quiet", "--set-upstream", "origin", branch], timeout: 300), next: "done")
        }
        return .run(git(["push", "--quiet"], timeout: 300), next: "done")
    default:
        return finish(request)
    }
}

func switchBranch(_ request: StepRequest, create: Bool) -> Step {
    if request.output != nil { return finish(request) }
    let name = request["name"]?.string ?? ""
    guard VersionControl.isValidBranchName(name) else { return .failure("“\(name)” is not a valid branch name.") }
    return .run(git(create ? ["switch", "--quiet", "--create", name] : ["switch", "--quiet", name]), next: "done")
}
