import CovePluginKit

/// Git through its machine-readable porcelain formats. Path lists travel on
/// standard input, so no command line outgrows a process request.
func provider(request: String, stdout: String) -> String {
    Steps.serve(request: request, stdout: stdout) { request in
        switch request.operation {
        case "status": status(request)
        case "history": history(request)
        case "branches": branches(request)
        case "diff": diff(request)
        case "stage": stage(request)
        case "unstage": unstage(request)
        case "discard": discard(request)
        case "commit": commit(request)
        case "pull": request.output == nil ? .run(git(["pull", "--ff-only", "--quiet"], timeout: 300), next: "done") : finish(request)
        case "push": push(request)
        case "switch-branch": switchBranch(request, create: false)
        case "create-branch": switchBranch(request, create: true)
        case "init": request.output == nil ? .run(git(["init", "--quiet"]), next: "done") : finish(request)
        case "context": context(request)
        case "locks": .result([])
        case "set-locked": .failure("Git does not lock files.")
        default: .failure("Git cannot \(request.operation).")
        }
    }
}

/// A git invocation that never waits on a prompt nobody can answer, and
/// reads paths literally rather than as patterns.
func git(_ arguments: [String], input: String? = nil, timeout: Int? = nil) -> Command {
    var command = Command(arguments, input: input, timeoutSeconds: timeout)
    command.environment = [("GIT_TERMINAL_PROMPT", "0"), ("GIT_OPTIONAL_LOCKS", "0"), ("GIT_EDITOR", "true"),
                           ("GIT_LITERAL_PATHSPECS", "1"), ("GCM_INTERACTIVE", "never"), ("NO_COLOR", "1")]
    return command
}

/// Paths for `--pathspec-from-file=- --pathspec-file-nul`.
func pathspecs(_ arguments: [String], _ paths: [String], timeout: Int? = nil) -> Command {
    git(arguments + ["--pathspec-from-file=-", "--pathspec-file-nul"], input: paths.joined(separatorByte: 0), timeout: timeout)
}

/// Ends an operation whose last command has run.
func finish(_ request: StepRequest) -> Step {
    guard let output = request.output else { return .failure("Git returned no output.") }
    return output.succeeded ? .result(.null) : .failure(output.message)
}

func strings(_ value: JSON?) -> [String] {
    var result: [String] = []
    for element in value?.array ?? [] { if let string = element.string { result.append(string) } }
    return result
}
