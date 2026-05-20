import Foundation

/// A point-in-time snapshot of the runtime scene, suitable for game progress saves.
///
/// A `GameSaveDocument` wraps an `EditorSceneManifest` captured while the game is
/// running (after physics, animations, etc. have modified entity transforms). Loading
/// a save replaces the current scene with this snapshot.
///
/// Files are stored under `.guava/game-saves/slot-{slot}.json`.
public struct GameSaveDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Save slot index (0-based). Slot 255 is reserved for the auto-save.
    public var slot: Int
    public var savedAt: String
    /// The full runtime manifest captured at save time.
    public var manifest: EditorSceneManifest

    public static let autoSaveSlot = 255

    public init(slot: Int, manifest: EditorSceneManifest) {
        self.schemaVersion = 1
        self.slot = slot
        self.savedAt = ISO8601DateFormatter().string(from: Date())
        self.manifest = manifest
    }
}

extension GameSaveDocument {
    /// Returns the file URL for `slot` relative to `projectDirectory`.
    public static func url(slot: Int, projectDirectory: String) -> URL {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("game-saves", isDirectory: true)
            .appendingPathComponent("slot-\(slot).json")
    }

    /// Encodes and writes this document atomically. Creates intermediate directories.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }

    /// Reads and decodes a `GameSaveDocument` from `url`, or returns nil if the file
    /// does not exist.
    public static func read(from url: URL) throws -> GameSaveDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GameSaveDocument.self, from: data)
    }
}
