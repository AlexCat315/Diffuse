import Swift

/// The version control step protocol behind `contributes.versionControl`.
///
/// The editor sends an operation such as `{"op":"status"}`. The plugin
/// answers with one step: a command to run, paths to move to the Trash, or
/// the result. The editor runs the command under the package's process
/// permission and calls back with the step's `next` state and the command's
/// output, so a long command never blocks the plugin host.
///
/// Output arrives a window at a time. A plugin that parses it page by page
/// answers each window with `page`, and the editor joins the fragments into
/// the result, so output of any size stays within one call's deadline.
public enum VersionControl {
    /// Serves one `provider` call. `stdout` is a window of the previous
    /// command's standard output. Process requests the editor routes through
    /// the plugin go to `guava:process/host` without being parsed.
    public static func serve(request: String, stdout: String,
                             _ respond: (VersionControlRequest) -> VersionControlStep) -> String {
        if let process = processRequest(request) { return GuavaHost.process(process) }
        guard let object = JSON.parse(request)?.object else {
            return VersionControlStep.failure("The editor sent a malformed request.").json.serialized
        }
        guard let operation = object["op"]?.string else {
            return VersionControlStep.failure("The request names no operation.").json.serialized
        }
        let output = object["output"].map {
            CommandOutput(status: $0["exit"]?.int ?? -1, stdout: stdout, stderr: $0["stderr"]?.string ?? "",
                          offset: $0["offset"]?.int ?? 0, isComplete: $0["complete"]?.bool ?? true)
        }
        let step = respond(VersionControlRequest(operation: operation, state: object["next"]?.string,
                                                 output: output, arguments: object))
        return step.json.serialized
    }

    /// The editor sends process requests as `{"process":<request>}` exactly;
    /// the inner text goes to the host as is.
    private static func processRequest(_ request: String) -> String? {
        let prefix: StaticString = "{\"process\":"
        guard request.hasBytePrefix(prefix) else { return nil }
        var request = request
        return request.withUTF8 { bytes in
            guard bytes.count > prefix.utf8CodeUnitCount, bytes[bytes.count - 1] == UInt8(ascii: "}") else { return nil }
            return String(utf8: UnsafeBufferPointer(rebasing: bytes[prefix.utf8CodeUnitCount..<(bytes.count - 1)]))
        }
    }

    /// Pages a JSON array whose elements come from records separated by
    /// `separator`. Use it from the operation's parse state; it keeps its own
    /// states while the editor pages.
    public static func pagedArray(_ request: VersionControlRequest, separator: UInt8,
                                  element: (String) -> JSON?) -> VersionControlStep {
        guard let output = request.output else { return .failure("No output to read.") }
        let continuing = request.state == "page" || request.state == "page,"
        var writer = JSONWriter(continuingArray: request.state == "page,")
        if !continuing { writer.beginArray() }
        let (records, consumed) = output.records(separatedBy: separator)
        for record in records {
            if let value = element(record) { writer.value(value) }
        }
        guard output.isComplete, consumed == output.byteCount else {
            return .page(writer.finish(), consumed: consumed, next: writer.hasElements ? "page," : "page")
        }
        writer.endArray()
        return .lastPage(writer.finish())
    }

    /// Branch names the editor accepts for every system: Git's ref rules,
    /// which also keep a name from reading as an option.
    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.first != UInt8(ascii: "-") else { return false }
        var previous: UInt8 = 0
        for byte in name.utf8 {
            if byte < 0x21 || byte == 0x7F { return false }
            switch byte {
            case UInt8(ascii: "~"), UInt8(ascii: "^"), UInt8(ascii: ":"), UInt8(ascii: "?"),
                 UInt8(ascii: "*"), UInt8(ascii: "["), UInt8(ascii: "\\"):
                return false
            case UInt8(ascii: ".") where previous == UInt8(ascii: "."):
                return false
            default: previous = byte
            }
        }
        return true
    }
}

public struct VersionControlRequest {
    public let operation: String
    /// The `next` state of the previous step; nil on an operation's first call.
    public let state: String?
    /// The previous step's command result, when it ran one.
    public let output: CommandOutput?
    let arguments: JSONObject

    /// An operation argument, such as `paths` for `stage`.
    public subscript(key: String) -> JSON? { arguments[key] }
}

public struct CommandOutput {
    public let status: Int
    /// A window of standard output, starting `offset` bytes into it.
    public let stdout: String
    public let stderr: String
    public let offset: Int
    /// Whether the window reaches the end of the output.
    public let isComplete: Bool

    public var succeeded: Bool { status == 0 }
    public var byteCount: Int { stdout.utf8.count }

    /// The whole output, or nil while the editor still has more to send: answer
    /// `VersionControlStep.wholeOutput(next:)` and it widens the window.
    public var whole: String? { offset == 0 && isComplete ? stdout : nil }

    /// The non-empty records ending in `separator`, and how many bytes of the
    /// window they cover. An unterminated last record counts only once the
    /// output is complete.
    public func records(separatedBy separator: UInt8) -> (records: [String], consumed: Int) {
        var records: [String] = [], consumed = 0
        var stdout = stdout
        let complete = isComplete
        stdout.withUTF8 { bytes in
            var start = 0
            for index in 0..<bytes.count where bytes[index] == separator {
                if index > start { records.append(String(utf8: UnsafeBufferPointer(rebasing: bytes[start..<index]))) }
                start = index + 1
            }
            if complete, bytes.count > start {
                records.append(String(utf8: UnsafeBufferPointer(rebasing: bytes[start...])))
                start = bytes.count
            }
            consumed = start
        }
        return (records, consumed)
    }

    /// The tool's own explanation: stderr, else stdout, trimmed and bounded.
    public var message: String {
        let text = trimmed(stderr).isEmpty ? trimmed(stdout) : trimmed(stderr)
        let bytes = Array(text.utf8)
        guard bytes.count > 2_000 else { return text }
        var start = bytes.count - 2_000
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private func trimmed(_ text: String) -> String {
        let bytes = Array(text.utf8)
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 }
        var start = 0, end = bytes.count
        while start < end, isSpace(bytes[start]) { start += 1 }
        while end > start, isSpace(bytes[end - 1]) { end -= 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}

/// One invocation of the package's command. The manifest's argument prefix
/// is prepended by the editor; `environment` names must be ones the
/// manifest permits.
public struct Command {
    public var arguments: [String]
    /// Text written to standard input, which is then closed.
    public var input: String?
    public var environment: [(name: String, value: String)] = []
    public var timeoutSeconds: Int?

    public init(_ arguments: [String], input: String? = nil, timeoutSeconds: Int? = nil) {
        self.arguments = arguments
        self.input = input
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum VersionControlStep {
    /// Runs the command, then calls back with `next` and its output.
    case run(Command, next: String)
    /// Runs the command; its standard output is the operation's result.
    case output(Command)
    /// Moves repository-relative paths to the Trash, then calls back with `next`.
    case trash([String], next: String)
    case result(JSON)
    /// Continues a paged result: `fragment` extends the result's JSON text and
    /// `consumed` bytes of this window were read. The editor calls back with
    /// `next` and the window that follows them.
    case page(String, consumed: Int, next: String)
    /// Ends a paged result; the result is every fragment joined.
    case lastPage(String)
    case failure(String)

    /// Asks for the whole output in one window, which the editor widens until
    /// it reaches the end.
    public static func wholeOutput(next: String) -> VersionControlStep { .page("", consumed: 0, next: next) }

    var json: JSON {
        switch self {
        case let .run(command, next):
            var object = command.json
            object["next"] = .string(next)
            return .object(object)
        case let .output(command): return .object(command.json)
        case let .trash(paths, next): return ["trash": JSON(paths), "next": .string(next)]
        case let .result(value): return ["result": value]
        case let .page(fragment, consumed, next):
            return ["emit": .string(fragment), "consumed": JSON(consumed), "next": .string(next)]
        case let .lastPage(fragment): return ["emit": .string(fragment), "done": true]
        case let .failure(message): return ["error": .string(message)]
        }
    }
}

extension Command {
    var json: JSONObject {
        var object: JSONObject = ["run": JSON(arguments)]
        if let input { object["input"] = .string(input) }
        if !environment.isEmpty {
            var variables = JSONObject()
            for variable in environment { variables[variable.name] = .string(variable.value) }
            object["env"] = .object(variables)
        }
        if let timeoutSeconds { object["timeout"] = JSON(timeoutSeconds) }
        return object
    }
}
