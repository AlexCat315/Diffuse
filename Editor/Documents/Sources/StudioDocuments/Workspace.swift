import Foundation

public struct TextDocument: Equatable, Sendable {
    public let path: String
    public var text: String
    let savedText: String?
    public var existsOnDisk: Bool { savedText != nil }
    public var isDirty: Bool { text != savedText }
}

public enum DocumentError: Error, LocalizedError {
    case invalidPath, unsupportedText, unsavedChanges, changedOnDisk
    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Use a project-relative file path inside the workspace"
        case .unsupportedText: "Text files must be UTF-8 and at most 4 MiB"
        case .unsavedChanges: "Save or discard the open document before replacing it"
        case .changedOnDisk: "The file changed on disk; reopen it before saving"
        }
    }
}

/// General text/code files; opening a file never builds or executes its contents.
public final class DocumentWorkspace: @unchecked Sendable {
    private let root: URL
    private let lock = NSRecursiveLock()
    private var storage: [String: TextDocument] = [:]
    public init(root: URL) { self.root = root.resolvingSymlinksInPath().standardizedFileURL }
    public var documents: [TextDocument] { withLock { storage.values.sorted { $0.path < $1.path } } }

    @discardableResult
    public func open(_ path: String) throws -> TextDocument {
        try withLock {
            if let document = storage[path] { return document }
            let url = try resolve(path)
            let text = try read(url)
            let document = TextDocument(path: path, text: text ?? "", savedText: text)
            storage[path] = document
            return document
        }
    }
    public func edit(_ path: String, text: String) throws {
        try withLock {
            guard text.utf8.count <= 4 * 1024 * 1024 else { throw DocumentError.unsupportedText }
            guard var document = storage[path] else { throw DocumentError.invalidPath }
            document.text = text
            storage[path] = document
        }
    }
    public func save(_ path: String) throws {
        try withLock {
            guard let document = storage[path] else { throw DocumentError.invalidPath }
            let url = try resolve(path)
            guard try read(url) == document.savedText else { throw DocumentError.changedOnDisk }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(document.text.utf8).write(to: url, options: .atomic)
            storage[path] = TextDocument(path: path, text: document.text, savedText: document.text)
        }
    }
    public func saveAll() throws { for document in documents where document.isDirty { try save(document.path) } }
    public func close(_ path: String, discard: Bool = false) throws {
        try withLock {
            guard discard || storage[path]?.isDirty != true else { throw DocumentError.unsavedChanges }
            storage.removeValue(forKey: path)
        }
    }
    public func files() -> [String] {
        withLock {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
            var paths: [String] = []
            let excluded: Set<String> = ["vendor", "build", "node_modules", "third-party"]
            while let url = enumerator.nextObject() as? URL, paths.count < 10000 {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true || excluded.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                if values?.isDirectory == false {
                    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                    let prefix = root.path + "/"
                    if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
                }
            }
            return paths.sorted()
        }
    }
    private func resolve(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") }) else { throw DocumentError.invalidPath }
        var ancestor = root
        for component in path.split(separator: "/") {
            ancestor.appendPathComponent(String(component))
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw DocumentError.invalidPath
            }
        }
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw DocumentError.invalidPath }
        return url
    }
    private func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 4 * 1024 * 1024 else { throw DocumentError.unsupportedText }
        let data = try Data(contentsOf: url)
        guard data.count <= 4 * 1024 * 1024, !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw DocumentError.unsupportedText }
        return text
    }
    private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}
