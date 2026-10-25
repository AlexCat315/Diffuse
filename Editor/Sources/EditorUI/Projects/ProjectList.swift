import Foundation

struct RecentProjectsStore {
    private static let defaultsKey = "GuavaRecentProjects"
    private static let maxCount = 8

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func all(defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        return (defaults.stringArray(forKey: defaultsKey) ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(canonicalPath)
            .filter { seen.insert($0).inserted }
            .prefix(maxCount).map { $0 }
    }

    static func record(_ path: String, defaults: UserDefaults = .standard) {
        let path = canonicalPath(path)
        var paths = all(defaults: defaults).filter { $0 != path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(maxCount)), forKey: defaultsKey)
    }

    static func remove(_ path: String, defaults: UserDefaults = .standard) {
        let path = canonicalPath(path)
        defaults.set(all(defaults: defaults).filter { $0 != path }, forKey: defaultsKey)
    }

    static func last() -> String? { all().first }
}
