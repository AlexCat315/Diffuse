import Foundation

/// Compares filesystem locations after resolving existing ancestors, including
/// Windows short paths and candidates that have not been created yet.
enum ProjectFilePath {
    static func canonicalURL(_ url: URL) -> URL {
        resolvedURL(url) ?? url.standardizedFileURL
    }

    private static func resolvedURL(_ url: URL) -> URL? {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        var visitedLinks = Set<String>()
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path) {
                guard visitedLinks.count < 40, visitedLinks.insert(ancestor.path).inserted else { return nil }
                ancestor = URL(fileURLWithPath: destination, relativeTo: ancestor.deletingLastPathComponent())
                    .absoluteURL.standardizedFileURL
                continue
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor, !ancestor.lastPathComponent.isEmpty else { break }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved
    }

    static func components(_ url: URL) -> [String] {
        var path = canonicalURL(url).path
        #if os(Windows)
        path = path.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("//?/UNC/") { path = "//" + path.dropFirst(8) }
        else if path.hasPrefix("//?/") { path = String(path.dropFirst(4)) }
        #endif
        return path.split(separator: "/").map(String.init)
    }

    static func comparableComponents(_ url: URL) -> [String] {
        let components = components(url)
        #if os(Windows)
        return components.map { $0.lowercased() }
        #else
        return components
        #endif
    }

    static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhs = resolvedURL(lhs), let rhs = resolvedURL(rhs) else { return false }
        return comparableComponents(lhs) == comparableComponents(rhs)
    }

    static func contains(_ candidate: URL, in root: URL, includingRoot: Bool = true) -> Bool {
        guard let candidate = resolvedURL(candidate), let root = resolvedURL(root) else { return false }
        let candidateParts = comparableComponents(candidate)
        let rootParts = comparableComponents(root)
        guard candidateParts.count >= rootParts.count,
              includingRoot || candidateParts.count > rootParts.count else { return false }
        return candidateParts.prefix(rootParts.count).elementsEqual(rootParts)
    }
}
