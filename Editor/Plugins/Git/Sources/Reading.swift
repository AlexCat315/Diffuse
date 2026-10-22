import GuavaPluginKit

func status(_ request: StepRequest) -> Step {
    guard let output = request.output else {
        return .run(git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]), next: "parse")
    }
    return output.succeeded ? statusPage(output, state: request.state) : .failure(output.message)
}

func history(_ request: StepRequest) -> Step {
    guard let output = request.output else {
        let limit = request["limit"]?.int ?? 50
        return .run(git(["log", "-n", "\(limit)", "--no-color", "--pretty=format:%H%x1f%an%x1f%at%x1f%s%x1e"]), next: "parse")
    }
    // A repository without commits has no log; that is not an error.
    guard output.succeeded else { return .result([]) }
    return Steps.pagedArray(request, separator: 0x1E, element: revision)
}

func branches(_ request: StepRequest) -> Step {
    guard let output = request.output else {
        return .run(git(["for-each-ref", "--format=%(HEAD)%1f%(refname)", "refs/heads", "refs/remotes"]), next: "parse")
    }
    return output.succeeded ? Steps.pagedArray(request, separator: 0x0A, element: branch) : .failure(output.message)
}

func diff(_ request: StepRequest) -> Step {
    guard let change = request["change"], let path = change["path"]?.string else { return .failure("No change to compare.") }
    if change["state"]?.string == "untracked" {
        // `--no-index` exits 1 when the files differ, which they always do.
        return .output(git(["diff", "--no-color", "--no-index", "--", "/dev/null", path]))
    }
    if change["staged"]?.bool == true {
        let paths = [change["originalPath"]?.string, path].compactMap { $0 }
        return .output(git(["diff", "--cached", "--no-color", "-M", "--"] + paths))
    }
    return .output(git(["diff", "--no-color", "--", path]))
}

/// Where the branch stands: `# branch.*` headers of a porcelain v2 listing.
struct Tracking {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// Whether earlier pages wrote changes.
    var hasChanges = false

    init() {}

    /// The state between pages, which carries the headers to the last one.
    init?(state: String?) {
        guard let state, state != "parse", let object = JSON.parse(state) else { return nil }
        branch = object["branch"]?.string
        upstream = object["upstream"]?.string
        ahead = object["ahead"]?.int ?? 0
        behind = object["behind"]?.int ?? 0
        hasChanges = object["more"]?.bool ?? false
    }

    var state: String {
        var object: JSONObject = ["ahead": JSON(ahead), "behind": JSON(behind), "more": .bool(hasChanges)]
        if let branch { object["branch"] = .string(branch) }
        if let upstream { object["upstream"] = .string(upstream) }
        return JSON.object(object).serialized
    }

    mutating func read(header record: Slice<UnsafeBufferPointer<UInt8>>) {
        // `# <key> <value>`
        guard let space = record.dropFirst(2).firstIndex(of: UInt8(ascii: " ")) else { return }
        let key = text(record[(record.startIndex + 2)..<space]), value = record[(space + 1)...]
        switch key {
        case "branch.head": branch = text(value) == "(detached)" ? nil : text(value)
        case "branch.upstream": upstream = text(value)
        case "branch.ab":
            // `+<ahead> -<behind>`
            let counts = value.split(separator: UInt8(ascii: " "))
            ahead = counts.first.map { number($0.dropFirst()) } ?? 0
            behind = counts.dropFirst().first.map { number($0.dropFirst()) } ?? 0
        default: break
        }
    }
}

/// The headers at the start of a porcelain v2 listing.
func tracking(of output: String) -> Tracking {
    var tracking = Tracking()
    var output = output
    output.withUTF8 { bytes in
        var records = Records(bytes: bytes, isComplete: true)
        while let record = records.next(), record.first == UInt8(ascii: "#") { tracking.read(header: record) }
    }
    return tracking
}

/// One window of `git status --porcelain=v2 --branch -z`, parsed on its
/// bytes. Changes are written as they are read; the branch headers ride in
/// the state and close the object on the last page.
func statusPage(_ output: CommandOutput, state: String?) -> Step {
    var tracking = Tracking(state: state) ?? Tracking()
    var writer = JSONWriter(continuingArray: tracking.hasChanges)
    if state == "parse" {
        writer.beginObject()
        writer.key("changes")
        writer.beginArray()
    }
    var consumed = 0
    var stdout = output.stdout
    stdout.withUTF8 { bytes in
        var records = Records(bytes: bytes, isComplete: output.isComplete)
        reading: while true {
            let start = records.index
            guard let record = records.next() else { break }
            guard let kind = record.first else { continue }
            switch kind {
            case UInt8(ascii: "#"):
                tracking.read(header: record)
            case UInt8(ascii: "?"):
                write(&writer, path: text(record.dropFirst(2)), original: nil, state: "untracked", staged: false)
            case UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "u"):
                // Ordinary entries have 8 fields before the path, renames 9, unmerged 10.
                let fields = kind == UInt8(ascii: "1") ? 8 : kind == UInt8(ascii: "2") ? 9 : 10
                var original: String?
                if kind == UInt8(ascii: "2") {
                    // A rename's original path is the next record; both go in one page.
                    guard let next = records.next() else {
                        records.index = start
                        break reading
                    }
                    original = text(next)
                }
                guard record.count > 4, let start = pathStart(record, after: fields) else { break }
                let path = text(record[start...])
                if kind == UInt8(ascii: "u") {
                    write(&writer, path: path, original: nil, state: "conflicted", staged: false)
                    break
                }
                if let state = fileState(record[record.startIndex + 2]) {
                    write(&writer, path: path, original: original, state: state, staged: true)
                }
                if let state = fileState(record[record.startIndex + 3]) {
                    write(&writer, path: path, original: nil, state: state == "renamed" ? "modified" : state, staged: false)
                }
            default: break
            }
        }
        consumed = records.index
    }
    tracking.hasChanges = writer.hasElements
    guard output.isComplete, consumed == output.byteCount else {
        return .page(writer.finish(), consumed: consumed, next: tracking.state)
    }
    writer.endArray()
    writer.key("branch"); writer.value(tracking.branch)
    writer.key("upstream"); writer.value(tracking.upstream)
    writer.key("ahead"); writer.value(tracking.ahead)
    writer.key("behind"); writer.value(tracking.behind)
    writer.endObject()
    return .lastPage(writer.finish())
}

private func write(_ writer: inout JSONWriter, path: String, original: String?, state: String, staged: Bool) {
    writer.beginObject()
    writer.key("path"); writer.value(path)
    if let original { writer.key("originalPath"); writer.value(original) }
    writer.key("state"); writer.value(state)
    writer.key("staged"); writer.value(staged)
    writer.endObject()
}

/// NUL-terminated records of a `-z` listing; an unterminated last record
/// counts once the output is complete.
private struct Records {
    let bytes: UnsafeBufferPointer<UInt8>
    let isComplete: Bool
    /// Where the next record starts: everything before it was read.
    var index = 0

    mutating func next() -> Slice<UnsafeBufferPointer<UInt8>>? {
        while index < bytes.count {
            var end = index
            while end < bytes.count, bytes[end] != 0 { end += 1 }
            guard end < bytes.count || isComplete else { return nil }
            let record = bytes[index..<end]
            index = min(end + 1, bytes.count)
            if !record.isEmpty { return record }
        }
        return nil
    }
}

private func text(_ bytes: Slice<UnsafeBufferPointer<UInt8>>) -> String {
    String(utf8: UnsafeBufferPointer(rebasing: bytes))
}

private func number(_ bytes: Slice<UnsafeBufferPointer<UInt8>>) -> Int {
    var value = 0
    for byte in bytes where byte >= 0x30 && byte <= 0x39 { value = value &* 10 &+ Int(byte - 0x30) }
    return value
}

/// The index after the `count`th space: where a path starts.
private func pathStart(_ record: Slice<UnsafeBufferPointer<UInt8>>, after count: Int) -> Int? {
    var spaces = 0
    for index in record.indices where record[index] == UInt8(ascii: " ") {
        spaces += 1
        if spaces == count { return index + 1 }
    }
    return nil
}

private func fileState(_ code: UInt8) -> String? {
    switch code {
    case UInt8(ascii: "M"), UInt8(ascii: "T"): "modified"
    case UInt8(ascii: "A"): "added"
    case UInt8(ascii: "D"): "deleted"
    case UInt8(ascii: "R"): "renamed"
    case UInt8(ascii: "C"): "copied"
    case UInt8(ascii: "U"): "conflicted"
    default: nil
    }
}

/// `%H 0x1f %an 0x1f %at 0x1f %s`; records end in 0x1e.
private func revision(_ record: String) -> JSON? {
    let fields = record.split(byte: 0x1F, omittingEmpty: false)
    guard fields.count == 4 else { return nil }
    let id = fields[0].split(byte: 0x0A).first ?? ""
    guard !id.isEmpty else { return nil }
    var revision: JSONObject = ["id": .string(id), "summary": .string(fields[3]), "author": .string(fields[1])]
    if let seconds = Int(fields[2]) { revision["date"] = JSON(seconds) }
    return .object(revision)
}

/// `%(HEAD) 0x1f %(refname)`, one per line.
private func branch(_ line: String) -> JSON? {
    let fields = line.split(byte: 0x1F, omittingEmpty: false)
    guard fields.count == 2 else { return nil }
    let reference = fields[1]
    if reference.hasBytePrefix("refs/heads/") {
        let name = String(decoding: reference.utf8.dropFirst(11), as: UTF8.self)
        return ["name": .string(name), "current": .bool(fields[0] == "*"), "remote": false]
    }
    guard reference.hasBytePrefix("refs/remotes/"), !reference.utf8.reversed().starts(with: "/HEAD".utf8.reversed()) else {
        return nil
    }
    return ["name": .string(String(decoding: reference.utf8.dropFirst(13), as: UTF8.self)), "current": false, "remote": true]
}
