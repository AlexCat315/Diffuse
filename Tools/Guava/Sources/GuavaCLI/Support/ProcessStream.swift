import Foundation
import Dispatch
import GuavaLogging

/// Machine-readable stdout is collected verbatim. Human output is teed to its original stream and the journal.
final class ProcessStream: @unchecked Sendable {
    let pipe = Pipe()
    private let group = DispatchGroup()
    private let destination: FileHandle?
    private let collect: Bool
    private let stream: String
    private let command: String
    private let context: Logger.Metadata
    private var collected = Data()

    init(command: String, stream: String, destination: FileHandle?, collect: Bool = false) {
        self.command = URL(fileURLWithPath: command).lastPathComponent; self.stream = stream
        self.destination = destination; self.collect = collect; context = LogContext.current
    }
    func start(pid: Int32) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            LogContext.withValues(context) {
                var buffered = Data()
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    if collect { collected.append(data) }
                    try? destination?.write(contentsOf: data)
                    if !collect {
                        buffered.append(data)
                        while let end = buffered.firstIndex(of: 10) {
                            record(buffered[..<end], pid: pid); buffered.removeSubrange(...end)
                        }
                        if buffered.count > 32768 { record(buffered, pid: pid); buffered.removeAll(keepingCapacity: true) }
                    }
                }
                if !buffered.isEmpty { record(buffered, pid: pid) }
            }
        }
    }
    func finish() -> Data { group.wait(); return collected }
    private func record(_ data: some DataProtocol, pid: Int32) {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !line.isEmpty else { return }
        LogSystem.logger("com.guava.cli.process").log(level: stream == "stderr" ? .warning : .info,
            "\(line)", metadata: ["command": "\(command)", "child_pid": "\(pid)", "stream": "\(stream)"], source: "process.\(stream)")
    }
}
