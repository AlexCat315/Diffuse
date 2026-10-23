import CapabilityRuntime
import Foundation

extension GuavaPluginManifest {
    /// Domain adapters call their declared entry points directly. They must
    /// not cause AI discovery or chat activation just because they use WIT.
    public func exposesToAI(entryPoint: String) -> Bool {
        guard entryPoint != "components", !host.entryPoints.contains(entryPoint) else { return false }
        let languages = (try? contributes.decode(LanguageContributionPoint.self)) ?? []
        return !languages.contains { $0.format?.entryPoint == entryPoint }
    }
}

/// Capabilities named by `host.processes[].entryPoints` are called by the
/// editor with whole tool output and never by the model. Their inputs are
/// checked for shape but not length, under `PluginResourceLimits.hostEntryPoint`.
extension ValidatedPluginPackage {
    public func isHostEntryPoint(_ capability: String) -> Bool {
        manifest.host.entryPoints.contains(capability)
    }

    public func inputSchema(for capability: WITCapabilityInput) -> JSONSchema {
        isHostEntryPoint(capability.name) ? capability.inputSchema.withoutSizeLimits : capability.inputSchema
    }

    public func limits(for capability: String, default limits: PluginResourceLimits) -> PluginResourceLimits {
        isHostEntryPoint(capability) ? .hostEntryPoint : limits
    }
}

extension JSONSchema {
    var withoutSizeLimits: JSONSchema {
        var schema = self
        schema.maximumLength = nil
        schema.maximumItems = nil
        schema.properties = properties.mapValues(\.withoutSizeLimits)
        schema.items = items.map(\.withoutSizeLimits)
        schema.oneOf = oneOf.map(\.withoutSizeLimits)
        return schema
    }
}
