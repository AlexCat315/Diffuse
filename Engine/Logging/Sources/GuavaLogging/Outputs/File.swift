#if !os(WASI)
import Foundation
import GuavaLogCore
import CGuavaLog

final class LogFile {
    let directory: URL
    private let configuration: LoggingConfiguration.Storage
    private let lease: Int
    private var handle: FileHandle?
    private var size = 0
    var file: URL { directory.appendingPathComponent("events.jsonl") }

    init(root: URL, application: String, configuration: LoggingConfiguration.Storage) throws {
        self.configuration = configuration
        let manager = FileManager.default
        let safe = String(application.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) ? String($0) : "_" }.joined().prefix(128))
        let parent = root.appendingPathComponent(safe.isEmpty || safe == "." || safe == ".." ? "Guava" : safe, isDirectory: true)
        directory = parent.appendingPathComponent("session-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent(".lease")
        guard manager.createFile(atPath: marker.path, contents: Data("GuavaLogging/1\n".utf8), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        lease = guava_log_lock_file(directory.appendingPathComponent(".lease").path)
        guard lease != -1 else { throw CocoaError(.fileWriteUnknown) }
        do { try open(); try prune(parent) } catch { guava_log_unlock_file(lease); throw error }
    }
    deinit { try? handle?.close(); guava_log_unlock_file(lease) }
    func append(_ data: Data) throws {
        guard data.count <= configuration.maximumFileBytes else { throw LoggingError.invalidConfiguration }
        if size > 0 && size + data.count > configuration.maximumFileBytes { try rotate() }
        try handle?.write(contentsOf: data); size += data.count
    }
    func flush() throws { try handle?.synchronize() }
    private func open() throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: file); size = 0
    }
    private func rotate() throws {
        try handle?.close(); handle = nil
        let manager = FileManager.default
        for index in stride(from: configuration.filesPerSession - 1, through: 1, by: -1) {
            let target = directory.appendingPathComponent("events.\(index).jsonl")
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            let source = index == 1 ? file : directory.appendingPathComponent("events.\(index - 1).jsonl")
            if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: target) }
        }
        if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
        try open()
    }
    private func prune(_ parent: URL) throws {
        let manager = FileManager.default
        let sessions = try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("session-") && UUID(uuidString: String($0.lastPathComponent.dropFirst(8))) != nil }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for old in sessions.dropFirst(configuration.retainedSessions) where old != directory {
            guard (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let marker = old.appendingPathComponent(".lease")
            guard (try? Data(contentsOf: marker)) == Data("GuavaLogging/1\n".utf8) else { continue }
            let lock = guava_log_lock_file(marker.path)
            if lock == -1 { continue }
            // Do not delete another process's active session or unrelated directory.
            try? manager.removeItem(at: old); guava_log_unlock_file(lock)
        }
    }
}
#endif
