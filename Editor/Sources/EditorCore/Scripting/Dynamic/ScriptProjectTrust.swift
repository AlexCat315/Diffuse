import Foundation

public enum ScriptProjectTrustState: Sendable, Equatable {
    case untrusted
    case trusted

    public var allowsExecution: Bool { self == .trusted }
}

/// User-owned workspace trust. The decision is deliberately stored outside
/// the project so a downloaded repository cannot mark itself as trusted.
final class ScriptProjectTrustStore: @unchecked Sendable {
    private struct Document: Codable {
        var version: Int
        var trustedProjectPaths: [String]
    }

    private let storageURL: URL
    private let lock = NSLock()
    private var trustedPaths: Set<String>
    let loadWarning: String?

    init(storageURL: URL? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.storageURL = storageURL ?? Self.defaultStorageURL(environment: environment)
        if let data = try? Data(contentsOf: self.storageURL),
           let document = try? JSONDecoder().decode(Document.self, from: data),
           document.version == 1 {
            self.trustedPaths = Set(document.trustedProjectPaths)
            self.loadWarning = nil
        } else if FileManager.default.fileExists(atPath: self.storageURL.path) {
            self.trustedPaths = []
            self.loadWarning = "Script workspace trust could not be read; execution remains blocked."
        } else {
            self.trustedPaths = []
            self.loadWarning = nil
        }
    }

    func state(for projectDirectory: String) -> ScriptProjectTrustState {
        lock.lock()
        defer { lock.unlock() }
        return trustedPaths.contains(Self.projectKey(projectDirectory)) ? .trusted : .untrusted
    }

    func setTrusted(_ trusted: Bool, projectDirectory: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.projectKey(projectDirectory)
        if trusted {
            trustedPaths.insert(key)
        } else {
            trustedPaths.remove(key)
        }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let document = Document(version: 1, trustedProjectPaths: trustedPaths.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: storageURL, options: .atomic)
    }

    private static func projectKey(_ projectDirectory: String) -> String {
        URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func defaultStorageURL(environment: [String: String]) -> URL {
        if let override = environment["GUAVA_EDITOR_STATE_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("script-workspace-trust.json")
        }
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".guava", isDirectory: true)
        return base
            .appendingPathComponent("GuavaEditor", isDirectory: true)
            .appendingPathComponent("script-workspace-trust.json")
    }
}

public enum ScriptProjectTrustError: Error, LocalizedError, Equatable {
    case executionBlocked

    public var errorDescription: String? {
        switch self {
        case .executionBlocked:
            return "Swift script execution is blocked until this project is explicitly trusted."
        }
    }
}
