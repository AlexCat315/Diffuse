import Foundation

/// Project-contained file operations with reference rewrites and rollback.
public enum EditorAssetFileWorkflow {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    private struct Rewrite {
        let url: URL
        let original: Data
        let replacement: Data
    }

    public static func referenceFiles(to source: URL, within root: URL) -> [URL] {
        textFiles(in: root).filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return rewrite(data, owner: url, source: source, destination: source,
                           root: root, detectOnly: true) != nil
        }
    }

    /// Restores a missing file and its model dependencies without overwriting
    /// shared files. Validation failures roll back only the newly copied files.
    public static func restoreMissing(from replacement: URL, to target: URL, within root: URL,
                                      validate: () throws -> Void = {}) throws {
        let fm = FileManager.default
        guard ProjectFilePath.isDescendant(target, of: root),
              !fm.fileExists(atPath: target.path), fm.fileExists(atPath: replacement.path),
              replacement.pathExtension.lowercased() == target.pathExtension.lowercased() else {
            throw Failure("Select a replacement of the same format for a missing project file.")
        }
        let files = [(replacement, target)] + AssetImportResolver.resolve(replacement, projectRoot: root).dropFirst().map {
            ($0.source, target.deletingLastPathComponent().appendingPathComponent($0.relativePath))
        }
        for (source, destination) in files {
            guard ProjectFilePath.isDescendant(destination, of: root), fm.fileExists(atPath: source.path) else {
                throw Failure("The replacement has missing dependencies or paths outside the project.")
            }
            if fm.fileExists(atPath: destination.path),
               (try Data(contentsOf: source)) != (try Data(contentsOf: destination)) {
                throw Failure("A different dependency already exists at \(destination.lastPathComponent).")
            }
        }
        var copied: [URL] = []
        do {
            for (source, destination) in files where !fm.fileExists(atPath: destination.path) {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
                copied.append(destination)
            }
            try validate()
        } catch {
            var failed: [String] = []
            for file in copied.reversed() {
                do { try fm.removeItem(at: file) }
                catch { failed.append(file.path) }
            }
            if !failed.isEmpty {
                throw Failure("\(error). Rollback could not restore: \(failed.joined(separator: ", "))")
            }
            throw error
        }
    }

    /// Moves a model and copies its relative dependencies to the new directory.
    /// Shared dependencies stay at their original locations for other models.
    @discardableResult
    public static func relocate(from source: URL, to destination: URL, within root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard ProjectFilePath.isDescendant(source, of: root), ProjectFilePath.isDescendant(destination, of: root) else {
            throw Failure("The source and destination must stay inside the project.")
        }
        guard !ProjectFilePath.sameLocation(source, destination) else { return [] }
        guard source.pathExtension.lowercased() == destination.pathExtension.lowercased() else {
            throw Failure("Keep the asset's file extension when renaming or moving it.")
        }
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else {
            throw Failure("The source is missing or the destination already exists.")
        }
        let dependencies = AssetImportResolver.resolve(source, projectRoot: root).dropFirst().map { dependency in
            (dependency.source, destination.deletingLastPathComponent().appendingPathComponent(dependency.relativePath))
        }.filter { !ProjectFilePath.sameLocation($0.0, $0.1) }
        for (original, target) in dependencies {
            guard ProjectFilePath.isDescendant(target, of: root), fm.fileExists(atPath: original.path) else {
                throw Failure("Repair missing model dependencies before moving this asset.")
            }
            if fm.fileExists(atPath: target.path),
               (try Data(contentsOf: original)) != (try Data(contentsOf: target)) {
                throw Failure("A different dependency already exists at \(target.lastPathComponent).")
            }
        }
        let rewrites = try textFiles(in: root).compactMap { url -> Rewrite? in
            let data = try Data(contentsOf: url)
            guard let replacement = rewrite(data, owner: url, source: source, destination: destination, root: root),
                  replacement != data else { return nil }
            return Rewrite(url: url, original: data, replacement: replacement)
        }
        var copied: [URL] = []
        var written: [Rewrite] = []
        var moved = false
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            for (original, target) in dependencies where !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: original, to: target)
                copied.append(target)
            }
            try fm.moveItem(at: source, to: destination)
            moved = true
            for item in rewrites {
                let target = ProjectFilePath.sameLocation(item.url, source) ? destination : item.url
                try item.replacement.write(to: target, options: .atomic)
                written.append(item)
            }
        } catch {
            var rollbackFailures: [String] = []
            for item in written.reversed() {
                let target = ProjectFilePath.sameLocation(item.url, source) ? destination : item.url
                do { try item.original.write(to: target, options: .atomic) }
                catch { rollbackFailures.append(target.path) }
            }
            if moved {
                do { try fm.moveItem(at: destination, to: source) }
                catch { rollbackFailures.append(source.path) }
            }
            for target in copied.reversed() {
                do { try fm.removeItem(at: target) }
                catch { rollbackFailures.append(target.path) }
            }
            if !rollbackFailures.isEmpty {
                throw Failure("\(error). Rollback could not restore: \(rollbackFailures.joined(separator: ", "))")
            }
            throw error
        }
        return rewrites.map(\.url)
    }

    public static func relativePath(_ url: URL, from directory: URL) -> String {
        let target = url.standardizedFileURL.pathComponents
        let base = directory.standardizedFileURL.pathComponents
        var shared = 0
        while shared < min(target.count, base.count), target[shared] == base[shared] { shared += 1 }
        return (Array(repeating: "..", count: base.count - shared) + Array(target.dropFirst(shared))).joined(separator: "/")
    }

    public static func projectRelativePath(_ url: URL, within root: URL) -> String? {
        guard ProjectFilePath.sameLocation(url, root) || ProjectFilePath.isDescendant(url, of: root) else { return nil }
        return relativePath(ProjectFilePath.canonicalURL(url), from: ProjectFilePath.canonicalURL(root))
    }

    private static func textFiles(in root: URL) -> [URL] {
        let excluded: Set<String> = [".git", ".build", "build", "vendor", "node_modules", "export", "compiled", "script-cache"]
        let extensions: Set<String> = ["json", "gltf", "obj", "mtl", "swift", "guavascene"]
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey], options: []) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
            if values.isDirectory == true {
                if excluded.contains(url.lastPathComponent) { enumerator.skipDescendants() }
            } else if values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()),
                      (values.fileSize ?? 0) < 8_000_000, ProjectFilePath.isDescendant(url, of: root) {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func rewrite(_ data: Data, owner: URL, source: URL, destination: URL,
                                root: URL, detectOnly: Bool = false) -> Data? {
        let oldID = relativePath(source, from: root)
        let newID = relativePath(destination, from: root)
        let oldRelative = relativePath(source, from: owner.deletingLastPathComponent())
        let newRelative = relativePath(destination, from: owner.deletingLastPathComponent())
        var matched = false
        if ["json", "gltf", "guavascene"].contains(owner.pathExtension.lowercased()),
           let json = try? JSONSerialization.jsonObject(with: data) {
            func transform(_ value: Any, key: String = "") -> Any {
                if let array = value as? [Any] { return array.map { transform($0, key: key) } }
                if let object = value as? [String: Any] {
                    return Dictionary(uniqueKeysWithValues: object.map { ($0.key, transform($0.value, key: $0.key)) })
                }
                guard let string = value as? String else { return value }
                if key == "uri" {
                    guard let decoded = string.removingPercentEncoding,
                          !decoded.contains("://"), !decoded.hasPrefix("data:"),
                          ProjectFilePath.sameLocation(owner.deletingLastPathComponent().appendingPathComponent(decoded), source)
                    else { return value }
                    matched = true
                    return newRelative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newRelative
                }
                if string == source.path { matched = true; return destination.path }
                if string == oldID { matched = true; return newID }
                if string == oldRelative || string.removingPercentEncoding == oldRelative {
                    matched = true
                    return string.contains("%") ? (newRelative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? newRelative) : newRelative
                }
                return value
            }
            let next = transform(json)
            guard matched else { return nil }
            return detectOnly ? data : try? JSONSerialization.data(withJSONObject: next, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if owner.pathExtension.lowercased() == "swift" {
            for (old, new) in [(oldID, newID), (source.path, destination.path)] {
                let oldLiteral = swiftLiteral(old)
                if text.contains(oldLiteral) { matched = true; text = text.replacingOccurrences(of: oldLiteral, with: swiftLiteral(new)) }
            }
        } else {
            text = text.components(separatedBy: "\n").map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("mtllib ") || trimmed.hasPrefix("map_") || trimmed.hasPrefix("bump ") else { return line }
                guard line.hasSuffix(" " + oldRelative) else { return line }
                matched = true
                return String(line.dropLast(oldRelative.count)) + newRelative
            }.joined(separator: "\n")
        }
        guard matched else { return nil }
        return detectOnly ? data : Data(text.utf8)
    }

    private static func swiftLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}
