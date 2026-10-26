import CapabilityRuntime
import Foundation
import PluginRuntime

/// Mobile hosts use an approved, immutable package in-process. iOS always uses
/// Pulley. Desktop Editor hosts retain the separate DiffusePluginHost process.
public actor EmbeddedPluginSession {
    public let inspection: PluginInspection
    private let execution: ExecutionPackage
    private let runtime: EmbeddedWasmtimeComponentRuntime
    private let registry: CapabilityRegistry
    private let limits: PluginResourceLimits

    public static func inspect(at url: URL, registry: CapabilityRegistry = .default) async throws -> PluginInspection {
        try await Task.detached {
            let execution = try ExecutionPackage(at: url, registry: registry)
            let runtime = try EmbeddedWasmtimeComponentRuntime()
            try runtime.validateComponent(execution.package, limits: .secureDefault)
            return PluginInspection(package: execution.package,
                contracts: PluginWITContractDeriver.contracts(for: execution.package))
        }.value
    }

    public static func open(at url: URL, authorization: PluginAuthorizationRecord,
                            registry: CapabilityRegistry = .default,
                            limits: PluginResourceLimits = .secureDefault) async throws -> EmbeddedPluginSession {
        try await Task.detached {
            try EmbeddedPluginSession(at: url, authorization: authorization, registry: registry, limits: limits)
        }.value
    }

    private init(at url: URL, authorization: PluginAuthorizationRecord,
                 registry: CapabilityRegistry, limits: PluginResourceLimits) throws {
        execution = try ExecutionPackage(at: url, registry: registry)
        inspection = PluginInspection(package: execution.package,
            contracts: PluginWITContractDeriver.contracts(for: execution.package))
        guard authorization.isStillValid(for: inspection) else { throw PluginAuthorizationError.noLongerValid }
        runtime = try EmbeddedWasmtimeComponentRuntime()
        try runtime.validateComponent(execution.package, limits: limits)
        self.registry = registry
        self.limits = limits
    }

    public func prepare(capabilityID: String, input: Data,
                        querySnapshot: PluginQuerySnapshot? = nil) async throws -> PluginPreparedCapabilityResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let result = try runtime.prepare(execution.package, capabilityID: capabilityID, input: input,
                                             querySnapshot: querySnapshot, limits: limits)
            try Task.checkCancellation()
            if inspection.manifest.access == .read {
                _ = try JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])
                return PluginPreparedCapabilityResult.read(result)
            }
            let calls = try JSONDecoder().decode([HostCapabilityCall].self, from: result)
            return .hostCalls(try PluginCompositionValidator.validate(calls, manifest: inspection.manifest,
                                                                      registry: registry, limits: limits))
        } onCancel: { [runtime, inspection] in
            runtime.interrupt(pluginID: inspection.manifest.id)
        }
    }
}
