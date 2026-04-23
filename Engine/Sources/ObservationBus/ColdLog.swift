import Foundation

public enum ObservationBusError: Error, CustomStringConvertible {
    case invalidColdLogDirectory(String)
    case coldLogWriteFailed(String)
    case coldLogReadFailed(String)

    public var description: String {
        switch self {
        case let .invalidColdLogDirectory(path):
            return "invalid cold log directory: \(path)"
        case let .coldLogWriteFailed(message):
            return "cold log write failed: \(message)"
        case let .coldLogReadFailed(message):
            return "cold log read failed: \(message)"
        }
    }
}

public final class ColdLog: @unchecked Sendable {
    public let directoryPath: String

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryPath: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ObservationBusError.invalidColdLogDirectory(directoryPath)
            }
        } else {
            try FileManager.default.createDirectory(atPath: directoryPath,
                                                    withIntermediateDirectories: true)
        }
        self.directoryPath = directoryPath
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func append(_ envelope: EventEnvelope) throws {
        let fileURL = url(for: envelope.streamID)
        let data = try encoder.encode(envelope)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw ObservationBusError.coldLogWriteFailed("cannot open \(fileURL.path)")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            throw ObservationBusError.coldLogWriteFailed(String(describing: error))
        }
    }

    public func read(streamID: String,
                     fromSeq: UInt64,
                     toSeq: UInt64? = nil) throws -> [EventEnvelope] {
        let fileURL = url(for: streamID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ObservationBusError.coldLogReadFailed(String(describing: error))
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        do {
            return try lines.compactMap { line in
                let envelope = try decoder.decode(EventEnvelope.self, from: Data(line.utf8))
                guard envelope.seq >= fromSeq else { return nil }
                if let toSeq, envelope.seq > toSeq { return nil }
                return envelope
            }
        } catch {
            throw ObservationBusError.coldLogReadFailed(String(describing: error))
        }
    }

    private func url(for streamID: String) -> URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent(sanitizedFileName(for: streamID))
    }

    private func sanitizedFileName(for streamID: String) -> String {
        var value = streamID
        ["/", ":", "\\", " "].forEach { token in
            value = value.replacingOccurrences(of: token, with: "_")
        }
        return value + ".jsonl"
    }
}