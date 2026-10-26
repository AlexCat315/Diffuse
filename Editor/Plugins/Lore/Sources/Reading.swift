import CovePluginKit

func status(_ request: StepRequest) -> Step {
    guard let output = request.output else { return .run(lore(["--json", "status", "--scan"], timeout: 120), next: "parse") }
    return output.succeeded ? statusPage(output, state: request.state) : .failure(output.message)
}

func history(_ request: StepRequest) -> Step {
    guard let output = request.output else {
        return .run(lore(["history", "\(request["limit"]?.int ?? 50)", "--oneline"]), next: "parse")
    }
    guard output.succeeded else { return .result([]) }
    return Steps.pagedArray(request, separator: 0x0A, element: revision)
}

/// Branches and locks are deduplicated, so they are read whole.
func branches(_ request: StepRequest) -> Step {
    guard let output = request.output else { return .run(lore(["--json", "branch", "list"]), next: "parse") }
    guard let text = output.whole else { return .wholeOutput(next: "parse") }
    return .result(parseBranches(text))
}

/// Locks live on the server; offline, the list is simply empty.
func locks(_ request: StepRequest) -> Step {
    guard let output = request.output else { return .run(lore(["--json", "lock", "status"]), next: "parse") }
    guard output.succeeded else { return .result([]) }
    guard let text = output.whole else { return .wholeOutput(next: "parse") }
    return .result(parseLocks(text))
}

func diff(_ request: StepRequest) -> Step {
    guard let path = request["change"]?["path"]?.string else { return .failure("No change to compare.") }
    return .output(lore(["diff", path]))
}

private func event(_ line: String) -> (tag: String, data: JSON)? {
    guard let event = JSON.parse(line), let tag = event["tagName"]?.string else { return nil }
    return (tag, event["data"] ?? [:])
}

private func events(_ output: String) -> [(tag: String, data: JSON)] {
    output.split(byte: 0x0A).compactMap(event)
}

/// Lore serializes some flags as booleans and others as 0/1 integers.
private func flag(_ value: JSON?) -> Bool {
    switch value {
    case let .bool(flag)?: flag
    case let .number(number)?: number != 0
    default: false
    }
}

private func number(_ value: JSON?) -> Int { value?.int ?? 0 }

private func nonEmpty(_ value: JSON?) -> String? {
    guard let string = value?.string, !string.isEmpty else { return nil }
    return string
}

/// One window of the `status --json` event stream. File events are written
/// as they arrive; the revision event may come anywhere, so its fields ride
/// in the state and close the object on the last page.
func statusPage(_ output: CommandOutput, state: String?) -> Step {
    var tracking: JSONObject = ["branch": .null, "upstream": .null, "ahead": 0, "behind": 0, "more": false]
    if let state, state != "parse", let saved = JSON.parse(state)?.object { tracking = saved }
    var writer = JSONWriter(continuingArray: tracking["more"]?.bool ?? false)
    if state == "parse" {
        writer.beginObject()
        writer.key("changes")
        writer.beginArray()
    }
    let (lines, consumed) = output.records(separatedBy: 0x0A)
    for line in lines {
        guard let event = event(line) else { continue }
        let data = event.data
        switch event.tag {
        case "repositoryStatusRevision":
            let branch = nonEmpty(data["branchName"])
            tracking["branch"] = JSON(branch)
            if flag(data["remoteBranchExist"]) { tracking["upstream"] = JSON(branch) }
            let local = number(data["revisionLocalNumber"]), remote = number(data["revisionRemoteNumber"])
            if flag(data["isLocalAhead"]) { tracking["ahead"] = JSON(max(1, local - remote)) }
            if flag(data["isRemoteAhead"]) { tracking["behind"] = JSON(max(1, remote - local)) }
        case "repositoryStatusFile":
            guard let path = nonEmpty(data["path"]), data["type"]?.string != "directory" else { continue }
            let state: String
            if flag(data["flagConflict"]) && flag(data["flagConflictUnresolved"]) {
                state = "conflicted"
            } else {
                switch data["action"]?.string {
                case "add": state = "added"
                case "delete": state = "deleted"
                case "move": state = "renamed"
                case "copy": state = "copied"
                default: state = "modified"
                }
            }
            writer.beginObject()
            writer.key("path"); writer.value(path)
            if let from = nonEmpty(data["fromPath"]) { writer.key("originalPath"); writer.value(from) }
            writer.key("state"); writer.value(state)
            writer.key("staged"); writer.value(flag(data["flagStaged"]))
            writer.endObject()
        default: continue
        }
    }
    tracking["more"] = .bool(writer.hasElements)
    guard output.isComplete, consumed == output.byteCount else {
        return .page(writer.finish(), consumed: consumed, next: JSON.object(tracking).serialized)
    }
    writer.endArray()
    writer.key("branch"); writer.value(tracking["branch"] ?? .null)
    writer.key("upstream"); writer.value(tracking["upstream"] ?? .null)
    writer.key("ahead"); writer.value(tracking["ahead"] ?? 0)
    writer.key("behind"); writer.value(tracking["behind"] ?? 0)
    writer.endObject()
    return .lastPage(writer.finish())
}

/// `lore history --oneline` prints `<number> <first message line>`.
private func revision(_ line: String) -> JSON? {
    let parts = line.split(byte: UInt8(ascii: " "), maxSplits: 1, omittingEmpty: false)
    guard let number = parts.first, Int(number) != nil else { return nil }
    return ["id": .string(number), "summary": .string(parts.count > 1 ? parts[1] : "")]
}

/// A branch present locally and remotely is listed once.
func parseBranches(_ output: String) -> JSON {
    var names: [String] = [], branches: [JSON] = []
    for event in events(output) where event.tag == "branchListEntry" {
        guard let name = nonEmpty(event.data["name"]), !names.contains(name) else { continue }
        names.append(name)
        branches.append(["name": .string(name), "current": .bool(flag(event.data["isCurrent"])),
                         "remote": .bool(event.data["location"]?.string == "remote")])
    }
    return .array(branches)
}

func parseLocks(_ output: String) -> JSON {
    var paths: [String] = []
    for event in events(output) where event.tag == "lockFileStatus" || event.tag == "lockFileQuery" {
        if let path = nonEmpty(event.data["path"]) { paths.append(path) }
    }
    var unique: [String] = []
    for path in paths.sorted() where unique.last != path { unique.append(path) }
    return JSON(unique)
}
