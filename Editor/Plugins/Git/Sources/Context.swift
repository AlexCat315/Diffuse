import GuavaPluginKit

/// What the assistant reads about the working tree: the branch, how it stands
/// against its upstream and the changed files. The editor bounds the length.
func context(_ request: StepRequest) -> Step {
    guard let output = request.output else {
        return .run(git(["status", "--porcelain=v1", "--branch", "--untracked-files=normal"]), next: "summarize")
    }
    // Outside a Git working tree there is nothing to tell the assistant.
    guard output.succeeded else { return .result(.string("")) }
    guard let listing = output.whole else { return .wholeOutput(next: "summarize") }
    var lines: [String] = []
    var changes: [String] = []
    for line in listing.split(separator: "\n") {
        if line.hasPrefix("## ") {
            lines.append("Branch: " + String(line.dropFirst(3)))
        } else if line.count > 3 {
            changes.append(String(line))
        }
    }
    if changes.isEmpty {
        lines.append("Working tree clean.")
    } else {
        lines.append("Changed files (\(changes.count)), as `git status --short` shows them:")
        lines.append(contentsOf: changes.prefix(100))
        if changes.count > 100 { lines.append("… and \(changes.count - 100) more.") }
    }
    return .result(.string(lines.joined(separator: "\n")))
}
