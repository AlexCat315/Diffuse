import GuavaPluginKit

/// Lore (https://github.com/EpicGames/lore) through its CLI. Reads use the
/// `--json` event stream (one `{"tagName", "data"}` object per line); history
/// uses `--oneline`, whose JSON form carries no messages.
func provider(request: String, stdout: String) -> String {
    Steps.serve(request: request, stdout: stdout) { request in
        switch request.operation {
        case "status": status(request)
        case "history": history(request)
        case "branches": branches(request)
        case "locks": locks(request)
        case "diff": diff(request)
        case "stage": batches(request, ["stage"], strings(request["paths"]))
        case "unstage": batches(request, ["unstage"], strings(request["paths"]))
        case "set-locked":
            batches(request, ["lock", request["locked"]?.bool == true ? "acquire" : "release"], strings(request["paths"]))
        case "discard": discard(request)
        case "commit": commit(request)
        case "pull": request.output == nil ? .run(lore(["sync"], timeout: 600), next: "done") : finish(request)
        case "push": request.output == nil ? .run(lore(["push"], timeout: 600), next: "done") : finish(request)
        case "switch-branch": switchBranch(request, create: false)
        case "create-branch": switchBranch(request, create: true)
        case "init": initialize(request)
        default: .failure("Lore cannot \(request.operation).")
        }
    }
}

func lore(_ arguments: [String], timeout: Int? = nil) -> Command {
    var command = Command(arguments, timeoutSeconds: timeout)
    command.environment = [("NO_COLOR", "1")]
    return command
}

func finish(_ request: StepRequest) -> Step {
    guard let output = request.output else { return .failure("Lore returned no output.") }
    return output.succeeded ? .result(.null) : .failure(output.message)
}

func strings(_ value: JSON?) -> [String] {
    var result: [String] = []
    for element in value?.array ?? [] { if let string = element.string { result.append(string) } }
    return result
}

/// Lore takes paths as arguments, so long lists run in several commands,
/// each small enough for one process request. The state is the next offset.
func batches(_ request: StepRequest, _ arguments: [String], _ paths: [String],
             then next: Step = .result(.null)) -> Step {
    if let output = request.output, !output.succeeded { return .failure(output.message) }
    var start = request.state.flatMap { Int($0) } ?? 0
    guard start < paths.count else { return next }
    var batch: [String] = [], bytes = 0
    while start < paths.count, batch.count < 64, batch.isEmpty || bytes + paths[start].utf8.count < 6_000 {
        bytes += paths[start].utf8.count
        batch.append(paths[start])
        start += 1
    }
    return .run(lore(arguments + batch), next: "\(start)")
}
