import GuavaPluginKit

/// SwiftPM through the `package` permission. Builds, tests and programs run
/// streamed, so the editor shows their output as it arrives; once one exits,
/// this reads the whole output into problems and test results.
///
/// Requests: `describe`, `build`, `test` (optional `filter`, a test
/// identifier), `run` (`target`, an executable product), `clean`
/// and `resolve`. `test` also carries `known`, the identifiers already listed,
/// so a result named only by its function finds its test.
func tasks(request: String, stdout: String) -> String {
    Steps.serve(request: request, stdout: stdout) { request in
        if request.output != nil { return report(request) }
        switch request.operation {
        case "describe": return .run(Command(["package", "describe", "--type", "json"], timeoutSeconds: 300), next: "describe")
        case "build": return .run(streamed(["build"]), next: "report")
        case "test":
            if let filter = request["filter"]?.string { return .run(streamed(["test", "--filter", exactly(filter)]), next: "report") }
            return .run(streamed(["test"]), next: "report")
        case "run":
            guard let target = request["target"]?.string, !target.isEmpty, !target.hasBytePrefix("-") else {
                return .failure("Name the executable product to run.")
            }
            return .run(streamed(["run", target]), next: "report")
        case "clean": return .run(streamed(["package", "clean"]), next: "report")
        case "resolve": return .run(streamed(["package", "resolve"]), next: "report")
        default: return .failure("Swift packages cannot \(request.operation).")
        }
    }
}

private func streamed(_ arguments: [String]) -> Command {
    var command = Command(arguments)
    command.streams = true
    return command
}

/// The output an operation needs is read whole; the editor widens its window
/// until it holds everything.
private func report(_ request: StepRequest) -> Step {
    guard let output = request.output else { return .failure("No output to read.") }
    guard let text = output.whole else { return .wholeOutput(next: request.state ?? "report") }
    switch request.state {
    case "describe":
        guard output.succeeded else { return .failure(output.message) }
        guard let description = PackageDescription.read(text) else { return .failure("SwiftPM printed no package description.") }
        return .result(description)
    default:
        var result = JSONObject()
        result["exit"] = JSON(output.status)
        result["problems"] = Problems.read(text)
        if request.operation == "test" { result["tests"] = TestResults.read(text, known: strings(request["known"])) }
        return .result(.object(result))
    }
}

/// `swift test --filter` takes a regular expression; this one matches the
/// identifier and nothing else, with or without the module in front. The index
/// writes an XCTest method as `test()`, XCTest itself as `test`; either matches.
private func exactly(_ identifier: String) -> String {
    var bytes: [UInt8] = Array("(^|\\.)".utf8)
    var name = Array(identifier.utf8)
    let call = ends(name[...], with: "()")
    if call { name.removeLast(2) }
    for byte in name {
        switch byte {
        case UInt8(ascii: "."), UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"),
             UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"),
             UInt8(ascii: "^"), UInt8(ascii: "$"), UInt8(ascii: "|"), UInt8(ascii: "\\"):
            bytes.append(UInt8(ascii: "\\"))
        default: break
        }
        bytes.append(byte)
    }
    if call { bytes += Array("(\\(\\))?".utf8) }
    bytes.append(UInt8(ascii: "$"))
    return text(bytes[...])
}

func strings(_ value: JSON?) -> [String] {
    var result: [String] = []
    for element in value?.array ?? [] { if let string = element.string { result.append(string) } }
    return result
}

// MARK: Bytes

func text(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.withUnsafeBufferPointer { String(utf8: $0) }
}

/// The lines of `text`, without their line breaks or terminal colour codes
/// (`ESC [ … m`), which the compiler prints even into a pipe.
func lines(_ text: String) -> [[UInt8]] {
    var result: [[UInt8]] = [], current: [UInt8] = [], escape = 0
    for byte in text.utf8 {
        if escape == 1 { escape = byte == UInt8(ascii: "[") ? 2 : 0; continue }
        if escape == 2 { if byte >= 0x40, byte <= 0x7E { escape = 0 }; continue }
        if byte == 0x1B { escape = 1 }
        else if byte == 0x0A { result.append(current); current = [] }
        else if byte != 0x0D { current.append(byte) }
    }
    if !current.isEmpty { result.append(current) }
    return result
}

func starts(_ bytes: ArraySlice<UInt8>, with prefix: StaticString) -> Bool {
    let count = prefix.utf8CodeUnitCount
    guard bytes.count >= count else { return false }
    var index = bytes.startIndex
    for offset in 0..<count {
        if bytes[index] != prefix.utf8Start[offset] { return false }
        index += 1
    }
    return true
}

func ends(_ bytes: ArraySlice<UInt8>, with suffix: StaticString) -> Bool {
    let count = suffix.utf8CodeUnitCount
    guard bytes.count >= count else { return false }
    var index = bytes.endIndex - count
    for offset in 0..<count {
        if bytes[index] != suffix.utf8Start[offset] { return false }
        index += 1
    }
    return true
}

func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
    var start = bytes.startIndex, end = bytes.endIndex
    while start < end, bytes[start] == 0x20 || bytes[start] == 0x09 { start += 1 }
    while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 { end -= 1 }
    return bytes[start..<end]
}

func integer(_ bytes: ArraySlice<UInt8>) -> Int? {
    guard !bytes.isEmpty, bytes.count < 10 else { return nil }
    var value = 0
    for byte in bytes {
        guard byte >= 0x30, byte <= 0x39 else { return nil }
        value = value * 10 + Int(byte - 0x30)
    }
    return value
}

func index(of byte: UInt8, in bytes: ArraySlice<UInt8>, from start: Int? = nil) -> Int? {
    var index = start ?? bytes.startIndex
    while index < bytes.endIndex {
        if bytes[index] == byte { return index }
        index += 1
    }
    return nil
}
