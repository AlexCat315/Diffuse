/// Facets derived from contribution points, never an exclusive package kind.
public enum PluginCategory: String, CaseIterable, Codable, Sendable {
    case themes = "Themes"
    case languages = "Languages"
    case ai = "AI"
    case ui = "UI"
    case versionControl = "Version Control"
    case tasks = "Tasks"
    case other = "Other"

    static func categories(points: [String], hasCapabilities: Bool) -> [Self] {
        var categories = Set<Self>()
        for point in points {
            if point.hasPrefix("guava.theme/") { categories.insert(.themes) }
            else if point.hasPrefix("guava.language/") { categories.insert(.languages) }
            else if point.hasPrefix("guava.ai.") || point.hasPrefix("guava.agent/") { categories.insert(.ai) }
            else if point.hasPrefix("guava.ui.") || point.hasPrefix("guava.command/") { categories.insert(.ui) }
            else if point.hasPrefix("guava.vcs/") { categories.insert(.versionControl) }
            else if point.hasPrefix("guava.tasks/") { categories.insert(.tasks) }
            else { categories.insert(.other) }
        }
        if categories.isEmpty { categories.insert(hasCapabilities ? .ai : .other) }
        return allCases.filter { categories.contains($0) }
    }
}
