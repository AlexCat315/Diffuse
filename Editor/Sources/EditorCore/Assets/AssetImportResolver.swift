import Foundation

/// Resolves the complete set of files an asset import must copy into the
/// project: the picked file plus every external file it references,
/// transitively, with destination paths kept relative to the asset so the
/// references stay valid.
///
/// This mirrors how Unreal and Godot import a model — they pull its buffer and
/// texture dependencies along with it rather than copying a lone file — and
/// dispatches per format by extension so new importers slot in cleanly:
///   * `.gltf` → external `buffers[].uri` (`.bin`) + `images[].uri` (textures)
///   * `.obj`  → `mtllib` (`.mtl`) → `map_*` texture maps
///   * `.glb`  → self-contained (no dependencies)
public enum AssetImportResolver {
    /// Geometry formats the asset browser can import.
    public static let supportedModelExtensions: Set<String> = ["gltf", "glb", "obj"]
    public static let supportedTextureExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "tga", "bmp", "gif", "svg"]
    public static let supportedExtensions = supportedModelExtensions.union(supportedTextureExtensions)

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public struct ResolvedFile: Equatable {
        public let source: URL
        /// Path relative to the import destination folder.
        public let relativePath: String

        public init(source: URL, relativePath: String) {
            self.source = source
            self.relativePath = relativePath
        }
    }

    /// Every file to copy for importing `source`. The asset itself is first;
    /// dependencies follow. Duplicate, embedded (`data:`), remote (`http(s)`)
    /// and path-escaping references are dropped. Files that don't exist on disk
    /// are still listed (the caller decides how to report them) so resolution
    /// never throws.
    public static func resolve(_ source: URL) -> [ResolvedFile] {
        var files: [ResolvedFile] = []
        var seenSources = Set<String>()

        @discardableResult
        func add(source: URL, relativePath: String) -> Bool {
            guard let rel = sanitizedRelativePath(relativePath) else { return false }
            guard seenSources.insert(source.resolvingSymlinksInPath().path).inserted else { return false }
            files.append(ResolvedFile(source: source, relativePath: rel))
            return true
        }

        add(source: source, relativePath: source.lastPathComponent)

        switch source.pathExtension.lowercased() {
        case "gltf":
            for uri in gltfReferencedURIs(source) {
                if let dep = referenced(uri, from: source, destinationDir: "") {
                    add(source: dep.source, relativePath: dep.relativePath)
                }
            }
        case "obj":
            // .obj → mtllib(.mtl) → map_* textures, each resolved relative to
            // the file that references it (the .mtl may live in a subfolder).
            for mtlName in objMaterialLibraryNames(source) {
                guard let mtl = referenced(mtlName, from: source, destinationDir: "") else { continue }
                guard add(source: mtl.source, relativePath: mtl.relativePath) else { continue }
                let mtlDir = parentDirectory(of: mtl.relativePath)
                for texName in mtlTextureNames(mtl.source) {
                    if let tex = referenced(texName, from: mtl.source, destinationDir: mtlDir) {
                        add(source: tex.source, relativePath: tex.relativePath)
                    }
                }
            }
        default:
            break // .glb is self-contained
        }
        return files
    }

    // MARK: - glTF

    private static func gltfReferencedURIs(_ gltf: URL) -> [String] {
        guard let data = try? Data(contentsOf: gltf),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var uris: [String] = []
        for key in ["buffers", "images"] {
            guard let entries = root[key] as? [[String: Any]] else { continue }
            for entry in entries {
                if let uri = entry["uri"] as? String { uris.append(uri) }
            }
        }
        return uris
    }

    // MARK: - OBJ / MTL

    private static func objMaterialLibraryNames(_ obj: URL) -> [String] {
        // `mtllib` may list several libraries on one line.
        directiveTails(in: obj, keyword: "mtllib")
    }

    private static func mtlTextureNames(_ mtl: URL) -> [String] {
        // Each map directive's filename is the LAST whitespace token; option
        // flags (`-o`, `-s`, `-bm`, …) precede it. Covers the common authoring
        // case without a full option parser.
        let keywords: Set<String> = ["map_kd", "map_ka", "map_ks", "map_ns", "map_d",
                                     "map_bump", "bump", "disp", "decal", "refl", "norm"]
        guard let text = readText(mtl) else { return [] }
        var names: [String] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2, keywords.contains(tokens[0].lowercased()),
                  let last = tokens.last else { continue }
            names.append(last)
        }
        return names
    }

    /// Whitespace tokens following `keyword` on each matching line.
    private static func directiveTails(in file: URL, keyword: String) -> [String] {
        guard let text = readText(file) else { return [] }
        var values: [String] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2, tokens[0].lowercased() == keyword else { continue }
            values.append(contentsOf: tokens.dropFirst())
        }
        return values
    }

    private static func readText(_ url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        return try? String(contentsOf: url, encoding: .isoLatin1)
    }

    // MARK: - Reference resolution

    /// Resolves a URI referenced by `referencingFile` (which itself lands at
    /// `destinationDir` within the project) into an absolute source path and the
    /// destination-relative path that keeps the reference intact.
    private static func referenced(_ uri: String,
                                   from referencingFile: URL,
                                   destinationDir: String) -> (source: URL, relativePath: String)? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty,
              !lower.hasPrefix("data:"),
              !lower.hasPrefix("http://"),
              !lower.hasPrefix("https://")
        else { return nil }
        let decoded = (trimmed.removingPercentEncoding ?? trimmed)
            .replacingOccurrences(of: "\\", with: "/")
        guard let relativeToReferencer = sanitizedRelativePath(decoded) else { return nil }
        let source = referencingFile.deletingLastPathComponent()
            .appendingPathComponent(relativeToReferencer)
        let destination = destinationDir.isEmpty
            ? relativeToReferencer
            : destinationDir + "/" + relativeToReferencer
        guard let relativePath = sanitizedRelativePath(destination) else { return nil }
        return (source, relativePath)
    }

    private static func parentDirectory(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    /// Normalizes a relative path and rejects anything that would escape the
    /// destination folder (absolute paths, drive letters, `..` segments).
    public static func sanitizedRelativePath(_ path: String) -> String? {
        let portablePath = path.replacingOccurrences(of: "\\", with: "/")
        guard !portablePath.isEmpty,
              !portablePath.hasPrefix("/"),
              portablePath.range(of: "^[A-Za-z]:", options: .regularExpression) == nil
        else { return nil }

        var components: [Substring] = []
        for component in portablePath.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else { return nil }
            components.append(component)
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}
