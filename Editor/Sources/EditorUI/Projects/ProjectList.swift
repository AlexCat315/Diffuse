import Foundation

/// The projects the window keeps open across launches, in sidebar order, and
/// the one in front.
struct EditorProjectList: Equatable {
    private static let openKey = "CoveOpenProjects"
    private static let activeKey = "CoveActiveProject"

    var paths: [String] = []
    var active: String?

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func load(defaults: UserDefaults = .standard) -> EditorProjectList {
        var seen = Set<String>()
        let paths = (defaults.stringArray(forKey: openKey) ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(canonicalPath)
            .filter { seen.insert($0).inserted }
        let active = defaults.string(forKey: activeKey).map(canonicalPath)
        return EditorProjectList(paths: paths, active: active.flatMap { paths.contains($0) ? $0 : nil })
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(paths, forKey: Self.openKey)
        if let active { defaults.set(active, forKey: Self.activeKey) }
        else { defaults.removeObject(forKey: Self.activeKey) }
    }
}
