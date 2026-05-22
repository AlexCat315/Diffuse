import Foundation

struct RecentProjectsStore {
    private static let defaultsKey = "GuavaRecentProjects"
    private static let maxCount = 8

    static func all() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    static func record(_ path: String) {
        var paths = all().filter { $0 != path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(maxCount)), forKey: defaultsKey)
    }

    static func remove(_ path: String) {
        UserDefaults.standard.set(all().filter { $0 != path }, forKey: defaultsKey)
    }

    static func last() -> String? { all().first }
}
