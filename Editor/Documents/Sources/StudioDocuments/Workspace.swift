import Foundation

public struct TextDocument: Equatable, Sendable {
    public let path: String
    public var text: String
    let savedText: String?
    public var existsOnDisk: Bool { savedText != nil }
    public var isDirty: Bool { text != savedText }
}

public enum DocumentError: Error, LocalizedError {
    case invalidPath, unsupportedText, unsavedChanges, changedOnDisk, alreadyExists
    public var errorDescription: String? {
        switch self {
        case .alreadyExists: "A file or folder with that name already exists"
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
    /// Writes a new file; an existing file is never replaced.
    public func create(_ path: String, text: String = "") throws {
        try withLock {
            let url = try resolve(path)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw DocumentError.alreadyExists }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        }
    }
    /// Renames a file or folder; open documents beneath it follow the move.
    public func move(_ path: String, to destination: String) throws {
        try withLock {
            let source = try resolve(path), target = try resolve(destination)
            guard !storage.keys.contains(where: { ($0 == path || $0.hasPrefix(path + "/")) && storage[$0]?.isDirty == true }) else {
                throw DocumentError.unsavedChanges
            }
            guard !FileManager.default.fileExists(atPath: target.path) else { throw DocumentError.alreadyExists }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: target)
            for key in Array(storage.keys) where key == path || key.hasPrefix(path + "/") {
                guard let document = storage.removeValue(forKey: key) else { continue }
                let moved = destination + key.dropFirst(path.count)
                storage[moved] = TextDocument(path: moved, text: document.text, savedText: document.savedText)
            }
        }
    }
    /// Moves a file or folder to recoverable trash and closes documents beneath it.
    /// Hosts without Foundation's Trash API retain it in `.cove/trash`.
    public func remove(_ path: String) throws {
        try withLock {
            _ = try resolve(path)
            try WorkspaceTrash.remove(path, in: root)
            for key in Array(storage.keys) where key == path || key.hasPrefix(path + "/") { storage.removeValue(forKey: key) }
        }
    }
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
                if url.lastPathComponent.hasPrefix(".") { enumerator.skipDescendants(); continue }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true || excluded.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                if values?.isDirectory == false {
                    let path = url.standardizedFileURL.path
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
        // Components are already bounded and checked for symlinks. Resolving again
        // on Windows changes an existing path to an extended-length path while a
        // root that did not exist at initialization keeps its original spelling.
        return ancestor.standardizedFileURL
    }
    private func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 4 * 1024 * 1024 else { throw DocumentError.unsupportedText }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 4 * 1024 * 1024, !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw DocumentError.unsupportedText }
        return text
    }
    private func withLock<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
}
