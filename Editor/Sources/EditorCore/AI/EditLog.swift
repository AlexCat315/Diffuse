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
        let enc = JSONEncoder()
        enc.outputFormatting = []
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    public func append(_ edit: Edit) throws {
        let lineData = try encoder.encode(edit)
        var data = lineData
        data.append(0x0A)
        try lock.withLock {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
