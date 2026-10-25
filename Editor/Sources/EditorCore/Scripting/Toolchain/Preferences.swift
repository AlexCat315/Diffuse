private import GuavaFileSystem
public import Foundation

public struct SwiftToolchainPreferences: Codable, Sendable, Equatable {
    public var selectedPath: String?
    public var releaseVersion = "6.4.1"

    public init() {}

    private enum CodingKeys: String, CodingKey { case selectedPath, releaseVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedPath = try values.decodeIfPresent(String.self, forKey: .selectedPath)
        releaseVersion = try values.decodeIfPresent(String.self, forKey: .releaseVersion) ?? Self().releaseVersion
    }

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("GuavaStudio/SwiftToolchains", isDirectory: true)
    }

    public static func load(from directory: URL = Self.directory) -> Self {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("preferences.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save(to directory: URL = Self.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicFile.write(JSONEncoder().encode(self), to: directory.appendingPathComponent("preferences.json"))
    }
}
