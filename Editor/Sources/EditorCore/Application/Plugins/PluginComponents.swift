import Foundation
import PluginRuntime
import SceneRuntime

/// Component declarations contributed by enabled plugins.
///
/// A plugin declares components as serialized `ComponentDescription` values, so
/// the host owns storage, serialization, the generated inspector form and the
/// AI/MCP schema. Registrations are session state: they are not serialized with
/// the scene, and disabling a plugin withdraws them from new scenes.
public final class PluginComponentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var declarations: [String: [ComponentDescription]] = [:]

    public init() {}

    public var isEmpty: Bool {
        lock.withLock { declarations.isEmpty }
    }

    public func set(_ descriptions: [ComponentDescription], pluginID: String) {
        lock.withLock { declarations[pluginID] = descriptions }
    }

    public func remove(pluginID: String) {
        lock.withLock { _ = declarations.removeValue(forKey: pluginID) }
    }

    /// A fresh registry carrying built-ins plus every declaration. Callers own the
    /// copy: registering later declarations does not mutate scenes built earlier.
    public func registry() -> ComponentRegistry {
        let installed = lock.withLock { declarations }
        var registry = ComponentRegistry.builtIn
        registry.registerScriptCodec()
        for pluginID in installed.keys.sorted() {
            // Declarations were validated when the plugin was enabled.
            try? registry.register(contentsOf: installed[pluginID] ?? [])
        }
        return registry
    }

    /// Withdraws and re-installs declarations on a live scene. Entities keep their
    /// authored documents; a withdrawn component simply stops being serialized.
    public func apply(to scene: inout SceneRuntime) {
        scene.componentRegistry = registry()
    }
}

/// Decodes the `components` capability payload of one plugin.
public enum PluginComponentDeclaration {
    public static func decode(_ payload: Data) throws -> [ComponentDescription] {
        try ComponentDeclarations.decode(payload)
    }
}
