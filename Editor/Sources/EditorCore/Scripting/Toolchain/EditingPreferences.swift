private import CoveFileSystem
public import Foundation

/// How Swift files are edited, for every project on this machine.
public struct SwiftEditingPreferences: Codable, Sendable, Equatable {
    /// Saving a Swift file formats it through the language service first.
    public var formatsOnSave = false

    public init() {}

    private enum CodingKeys: String, CodingKey { case formatsOnSave }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatsOnSave = try values.decodeIfPresent(Bool.self, forKey: .formatsOnSave) ?? Self().formatsOnSave
    }

    private static var url: URL {
        SwiftToolchainPreferences.directory.deletingLastPathComponent().appendingPathComponent("Swift/editing.json")
    }

    public static func load() -> Self {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(self), to: Self.url)
    }
}
