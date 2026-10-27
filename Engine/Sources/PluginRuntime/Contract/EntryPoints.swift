import CapabilityRuntime
import Foundation

extension CovePluginManifest {
    /// Only capabilities a `cove.ai.tool/v1` names reach the model; everything
    /// else a package exports is called by the editor alone.
    public func exposesToAI(entryPoint: String) -> Bool {
        aiTool(entryPoint: entryPoint) != nil
    }

    public func aiTool(entryPoint: String) -> AIToolContribution? {
        let harnesses = (try? contributes.decode(AIHarnessContributionPoint.self)) ?? []
        guard entryPoint != "components", !host.entryPoints.contains(entryPoint),
              !harnesses.contains(where: { $0.entryPoint == entryPoint }) else { return nil }
        return ((try? contributes.decode(AIToolContributionPoint.self)) ?? []).first { $0.entryPoint == entryPoint }
    }
}

/// Capabilities named by `host.processes[].entryPoints` are called by the
/// editor with whole tool output and never by the model, and so are harness
/// entry points, which get whole turns. Their inputs are checked for shape but
/// not length, under `PluginResourceLimits.hostEntryPoint`.
extension ValidatedPluginPackage {
    public func isHostEntryPoint(_ capability: String) -> Bool {
        manifest.host.entryPoints.contains(capability)
            || ((try? manifest.contributes.decode(AIHarnessContributionPoint.self)) ?? []).contains { $0.entryPoint == capability }
    }

    public func inputSchema(for capability: PluginEntryContract) -> JSONSchema {
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
