import CapabilityRuntime
import Foundation

/// The only write-shaped value a WASI plugin may return. There is no public
/// plugin API for SceneMutation, TransactionOperation, pointers, or runtime
/// handles.
public struct HostCapabilityCall: Codable, Sendable, Equatable {
    public var capabilityID: String
    public var version: Int
    public var arguments: Data

    public init(capabilityID: String, version: Int, arguments: Data) {
        self.capabilityID = capabilityID
        self.version = version
        self.arguments = arguments
    }
}

public enum PluginCompositionError: Error, Sendable, Equatable, CustomStringConvertible {
    case tooManyCalls
    case outputTooLarge
    case capabilityNotGranted(String)
    case capabilityChanged(String)
    case pluginPrimitiveNotAllowed(String)
    case externalSideEffectNotAllowed(String)
    case invalidArguments(capabilityID: String, reason: String)
    case emptyWriteComposition
    case unsafeHostPrimitive(String)

    public var description: String {
        switch self {
        case .tooManyCalls: return "plugin composition returned too many host calls"
        case .outputTooLarge: return "plugin composition output exceeds 1 MiB"
        case let .capabilityNotGranted(id): return "host capability '\(id)' was not granted to this plugin"
        case let .capabilityChanged(id): return "host capability '\(id)' changed version"
        case let .pluginPrimitiveNotAllowed(id): return "plugin capability '\(id)' cannot be used as a primitive"
        case let .externalSideEffectNotAllowed(id): return "external side-effect capability '\(id)' is disabled"
        case let .invalidArguments(id, reason): return "invalid arguments for '\(id)': \(reason)"
        case .emptyWriteComposition: return "a plugin write capability must return at least one host call"
        case let .unsafeHostPrimitive(id):
            return "host capability '\(id)' is not an AI-exposed strict write primitive"
        }
    }
}

public enum PluginCompositionValidator {
    public static func validate(_ calls: [HostCapabilityCall],
                                manifest: GuavaPluginManifest,
                                registry: CapabilityRegistry = .default,
                                limits: PluginResourceLimits = .secureDefault) throws -> [HostCapabilityCall] {
        try PluginManifestValidator.validate(manifest, registry: registry)
        if manifest.access.isWrite, calls.isEmpty {
            throw PluginCompositionError.emptyWriteComposition
        }
        guard calls.count <= limits.maximumCapabilities else { throw PluginCompositionError.tooManyCalls }
        let encodedSize = (try? JSONEncoder().encode(calls).count) ?? Int.max
        guard encodedSize <= limits.maximumOutputBytes else { throw PluginCompositionError.outputTooLarge }
        let granted = Set(manifest.composableHostCapabilities)
        for call in calls {
            guard granted.contains(call.capabilityID) else {
                throw PluginCompositionError.capabilityNotGranted(call.capabilityID)
            }
            guard let descriptor = registry.descriptor(for: call.capabilityID) else {
                throw PluginCompositionError.capabilityNotGranted(call.capabilityID)
            }
            let contract = descriptor.contract
            guard contract.source.kind == .builtin else {
                throw PluginCompositionError.pluginPrimitiveNotAllowed(call.capabilityID)
            }
            guard descriptor.isAIExposed,
                  contract.access.isWrite,
                  contract.inputSchema.isStrictCapabilityInput else {
                throw PluginCompositionError.unsafeHostPrimitive(call.capabilityID)
            }
            guard call.version == contract.version else {
                throw PluginCompositionError.capabilityChanged(call.capabilityID)
            }
            guard contract.access != .externalSideEffect else {
                throw PluginCompositionError.externalSideEffectNotAllowed(call.capabilityID)
            }
            do {
                try JSONSchemaValidator.validate(data: call.arguments, against: contract.inputSchema)
            } catch {
                throw PluginCompositionError.invalidArguments(capabilityID: call.capabilityID,
                                                              reason: String(describing: error))
            }
        }
        return calls
    }
}
