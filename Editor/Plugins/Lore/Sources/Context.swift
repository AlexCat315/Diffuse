import CovePluginKit

/// What the assistant reads about the working tree: the branch, how it stands
/// against the server, the changed files and the files locked in this
/// workspace, which a change must not touch without the lock.
func context(_ request: StepRequest) -> Step {
    guard let output = request.output else {
        return .run(lore(["--json", "status", "--scan"], timeout: 120), next: "status")
    }
    if request.state == "status" {
        // Outside a Lore workspace there is nothing to tell the assistant.
        guard output.succeeded else { return .result(.string("")) }
        guard output.whole != nil else { return .wholeOutput(next: "status") }
        guard case let .lastPage(listing) = statusPage(output, state: "parse"), let status = JSON.parse(listing) else {
            return .failure("Lore returned a status the plugin cannot read.")
        }
        return .run(lore(["--json", "lock", "status"]), next: JSON.object(["summary": .string(summary(status))]).serialized)
    }
    let summary = JSON.parse(request.state ?? "")?["summary"]?.string ?? ""
    guard output.succeeded else { return .result(.string(summary)) }
    guard let text = output.whole else { return .wholeOutput(next: request.state ?? "") }
    let locks = parseLocks(text).array?.compactMap { $0.string } ?? []
    var lines = [summary]
    if !locks.isEmpty {
        lines.append("Locked files (\(locks.count)):")
        lines.append(contentsOf: locks.prefix(100))
    }
    return .result(.string(lines.joined(separator: "\n")))
}

private func summary(_ status: JSON) -> String {
    var lines: [String] = []
    var branch = "Branch: " + (status["branch"]?.string ?? "(none)")
    let ahead = status["ahead"]?.int ?? 0, behind = status["behind"]?.int ?? 0
    if ahead > 0 || behind > 0 { branch += " (ahead \(ahead), behind \(behind))" }
    lines.append(branch)
    let changes = status["changes"]?.array ?? []
    if changes.isEmpty {
        lines.append("Working tree clean.")
    } else {
        lines.append("Changed files (\(changes.count)):")
        for change in changes.prefix(100) {
            let staged = change["staged"]?.bool == true ? ", staged" : ""
            lines.append("\(change["path"]?.string ?? "?") (\(change["state"]?.string ?? "modified")\(staged))")
        }
        if changes.count > 100 { lines.append("… and \(changes.count - 100) more.") }
    }
    return lines.joined(separator: "\n")
}
