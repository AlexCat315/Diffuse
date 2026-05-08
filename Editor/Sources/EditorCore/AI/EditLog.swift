import Foundation
import IntentRuntime

/// Append-only JSONL log of every applied Edit.
/// Written to `<project>/.guava/edit_log.jsonl`.
public final class EditLog: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(projectDirectory: String) {
        let guavaDir = URL(fileURLWithPath: projectDirectory)
            .appendingPathComponent(".guava", isDirectory: true)
        self.fileURL = guavaDir.appendingPathComponent("edit_log.jsonl")
        try? FileManager.default.createDirectory(at: guavaDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = []
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    public func append(_ edit: Edit) {
        guard let lineData = try? encoder.encode(edit) else { return }
        var data = lineData
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
