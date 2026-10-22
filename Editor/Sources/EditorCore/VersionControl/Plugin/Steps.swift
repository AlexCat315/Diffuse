import Foundation
import PluginRuntime

/// What an operation produced: the plugin's JSON result, or the standard
/// output of a command whose output is the result.
enum VersionControlOutcome {
    case result(Data)
    case output(String)
}

/// The editor half of the step protocol: the plugin decides each command, the
/// editor runs it through the plugin's process permission and calls back with
/// its output until the plugin returns a result. See GuavaPluginKit's
/// `VersionControl` for the plugin half.
///
/// Output goes to the plugin a window at a time. The plugin answers each
/// window with a fragment of the result and how much it read, so each call
/// stays short however much a command prints; one that reads nothing gets a
/// wider window.
extension VersionControlPlugin {
    static let window = 1 << 20

    /// Runs `operation` to its result. `resuming` continues as if a command had
    /// just printed `stdout`, for recorded output; `baseWindow` sizes windows.
    func perform(_ operation: [String: Any], resuming: (next: String, stdout: Data)? = nil,
                 baseWindow: Int = VersionControlPlugin.window) async throws -> VersionControlOutcome {
        let name = operation["op"] as? String ?? "operation"
        let failed = { (message: String) in
            VersionControlError.commandFailed(command: "\(self.provider.contribution.title) \(name)", message: message)
        }
        var request = operation
        // The last command's output, made valid UTF-8 once so window offsets
        // mean the same bytes on both sides.
        var pending = Data(), offset = 0, window = baseWindow
        if let resuming {
            request["next"] = resuming.next
            request["output"] = ["exit": 0, "stderr": ""]
            pending = Data(String(decoding: resuming.stdout, as: UTF8.self).utf8)
        }
        var fragments = Data()
        for _ in 0..<100_000 {
            var stdout = ""
            if var output = request["output"] as? [String: Any] {
                let end = Self.windowEnd(in: pending, from: offset, length: window)
                stdout = String(decoding: pending[offset..<end], as: UTF8.self)
                output["offset"] = offset
                output["complete"] = end == pending.endIndex
                request["output"] = output
            }
            let step = try await call(request, stdout: stdout)
            if let message = step["error"] as? String { throw failed(message) }
            if step.keys.contains("result") {
                return .result(try JSONSerialization.data(withJSONObject: step["result"] ?? NSNull(), options: .fragmentsAllowed))
            }
            if let fragment = step["emit"] as? String {
                fragments.append(Data(fragment.utf8))
                if step["done"] as? Bool == true { return .result(fragments) }
                let consumed = step["consumed"] as? Int ?? 0
                let end = Self.windowEnd(in: pending, from: offset, length: window)
                guard let next = step["next"] as? String, consumed >= 0, offset + consumed <= end else {
                    throw VersionControlError.unsupported("The \(provider.contribution.title) plugin read past its window.")
                }
                if consumed > 0 {
                    offset += consumed
                    window = baseWindow
                } else if end < pending.endIndex {
                    window *= 2
                } else {
                    throw VersionControlError.unsupported("The \(provider.contribution.title) plugin stopped reading \(name)'s output.")
                }
                request["next"] = next
                continue
            }
            request = operation
            if let paths = step["trash"] as? [String], let next = step["next"] as? String {
                try VersionControlFiles.trash(paths, in: workspace)
                request["next"] = next
                continue
            }
            guard let arguments = step["run"] as? [String] else {
                throw VersionControlError.unsupported("The \(provider.contribution.title) plugin sent an unknown step.")
            }
            let next = step["next"] as? String
            let output = try await run(arguments, input: step["input"] as? String,
                                       environment: step["env"] as? [String: String] ?? [:],
                                       timeout: .seconds(step["timeout"] as? Int ?? 60))
            guard let next else {
                guard output.status == 0 || !output.stdout.isEmpty else {
                    throw failed(String(decoding: output.stderr, as: UTF8.self))
                }
                return .output(String(decoding: output.stdout, as: UTF8.self))
            }
            request["next"] = next
            request["output"] = ["exit": Int(output.status), "stderr": String(decoding: output.stderr.suffix(16_384), as: UTF8.self)]
            pending = Data(String(decoding: output.stdout, as: UTF8.self).utf8)
            offset = 0
            window = baseWindow
            fragments = Data()
        }
        throw VersionControlError.unsupported("The \(provider.contribution.title) plugin did not finish \(name).")
    }

    private func call(_ request: [String: Any], stdout: String) async throws -> [String: Any] {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try await Task.detached { try self.invoke(encoded, stdout: stdout) }.value
        guard let step = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw VersionControlError.unsupported("The \(provider.contribution.title) plugin sent a malformed step.")
        }
        return step
    }

    /// Where a window of at most `length` bytes ends: before a UTF-8
    /// continuation byte, so a character is never split.
    static func windowEnd(in data: Data, from start: Int, length: Int) -> Int {
        let limit = min(start + length, data.endIndex)
        var end = limit
        while end < data.endIndex, end > start, data[end] & 0xC0 == 0x80 { end -= 1 }
        return end == start ? limit : end
    }

    // MARK: Processes

    struct Output {
        var stdout = Data()
        var stderr = Data()
        var status: Int32 = 0
    }

    /// Runs one command under the manifest's process permission, through the
    /// plugin host that enforces it.
    private func run(_ arguments: [String], input: String?, environment: [String: String],
                     timeout: Duration) async throws -> Output {
        let rule = provider.process
        var start = PluginProcessRequest(.start)
        start.permission = rule.id
        start.arguments = rule.argumentPrefix + arguments
        start.environment = tool.environment(allowing: rule.environmentKeys)
            .merging(environment.filter { rule.environmentKeys.contains($0.key) }) { $1 }
        let handle = try await process(start).handle
        do {
            let bytes = Data((input ?? "").utf8)
            for offset in stride(from: 0, to: bytes.count, by: 8_192) {
                var write = PluginProcessRequest(.write)
                write.handle = handle
                write.input = bytes.subdata(in: offset..<min(offset + 8_192, bytes.count))
                _ = try await process(write)
            }
            var close = PluginProcessRequest(.closeInput)
            close.handle = handle
            _ = try await process(close)

            var output = Output(), delay = 2
            let deadline = ContinuousClock.now + timeout
            var poll = PluginProcessRequest(.poll)
            poll.handle = handle
            while true {
                let update = try await process(poll)
                output.stdout.append(update.stdout)
                output.stderr.append(update.stderr)
                if let failure = update.failure { throw VersionControlError.unsupported(failure) }
                if let status = update.exitStatus {
                    output.status = status
                    return output
                }
                if !update.stdout.isEmpty || !update.stderr.isEmpty { delay = 2; continue }
                guard ContinuousClock.now < deadline else {
                    throw VersionControlError.commandFailed(command: "\(provider.contribution.title) \(arguments.first ?? "")",
                                                            message: "The command did not finish in time.")
                }
                try await Task.sleep(for: .milliseconds(delay))
                delay = min(delay * 2, 50)
            }
        } catch {
            var stop = PluginProcessRequest(.stop)
            stop.handle = handle
            _ = try? await process(stop)
            throw error
        }
    }

    /// Process requests reach `guava:process/host` through the plugin, which
    /// forwards the text after `{"process":` unparsed; the host checks it
    /// against the manifest.
    private func process(_ request: PluginProcessRequest) async throws -> PluginProcessUpdate {
        let forwarded = "{\"process\":" + String(decoding: try JSONEncoder().encode(request), as: UTF8.self) + "}"
        let response = try await Task.detached { try self.invoke(forwarded, stdout: "") }.value
        return try JSONDecoder().decode(PluginProcessUpdate.self, from: response)
    }
}
