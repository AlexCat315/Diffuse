import GuavaUIRuntime

/// Maps `WorkspacePanel.iconAssetKey` strings to bundled image resources.
/// The workspace stores only the string (the document is Codable); the host
/// registers concrete resources at startup. Unresolved keys fall back to the
/// text-pill rail button.
public enum WorkspacePanelIconCatalog {
    nonisolated(unsafe) private static var resources: [String: BundleImageResource] = [:]

    public static func register(_ key: String, _ resource: BundleImageResource) {
        resources[key] = resource
    }

    public static func resolve(_ key: String?) -> BundleImageResource? {
        key.flatMap { resources[$0] }
    }
}
