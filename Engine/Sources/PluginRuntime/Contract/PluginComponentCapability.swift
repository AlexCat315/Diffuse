import CapabilityRuntime
import Foundation

/// Reserved capability through which a plugin declares the components it owns.
///
/// The host calls it once, right after the plugin is enabled, and registers the
/// returned descriptions on the scene's component registry. Declarations are data
/// only: the plugin never ships native code for storage or UI.
public enum PluginComponentCapability {
    public static let name = "components"

    public static func capabilityID(pluginID: String) -> String {
        "\(pluginID).\(name)"
    }

    /// Input record the host sends. Plugins must declare it exactly:
    ///
    /// ```wit
    /// record components-input { include-all: bool }
    /// components: func(input: components-input) -> string;
    /// ```
    public static let input = Data(#"{"include-all":true}"#.utf8)

    public static func declaresComponents(_ contracts: [CapabilityContract], pluginID: String) -> Bool {
        contracts.contains { $0.id == capabilityID(pluginID: pluginID) }
    }
}
