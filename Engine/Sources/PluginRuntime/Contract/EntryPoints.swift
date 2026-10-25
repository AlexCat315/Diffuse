import CapabilityRuntime
import Foundation

extension GuavaPluginManifest {
    /// Only capabilities a `guava.ai.tool/v1` names reach the model; everything
    /// else a package exports is called by the editor alone.
    public func exposesToAI(entryPoint: String) -> Bool {
        aiTool(entryPoint: entryPoint) != nil
    }

    public func aiTool(entryPoint: String) -> AIToolContribution? {
        guard entryPoint != "components", !host.entryPoints.contains(entryPoint) else { return nil }
        return ((try? contributes.decode(AIToolContributionPoint.self)) ?? []).first { $0.entryPoint == entryPoint }
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
