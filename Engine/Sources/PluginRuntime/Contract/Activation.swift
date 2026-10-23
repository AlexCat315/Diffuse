import Foundation

public enum PluginActivationEvent {
    public static func isValid(_ value: String) -> Bool {
        if ["onStartup", "onAIChat"].contains(value) { return true }
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[1].isEmpty && parts[1].count <= 256
            && ["onLanguage", "onCommand", "onView", "onAIProvider", "onAgent", "onAITool",
                "onWorkspaceContains", "onURI"].contains(String(parts[0]))
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
