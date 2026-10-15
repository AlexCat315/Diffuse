import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import NativeRHI
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat


public enum EditorPluginCapabilityError: Error, Sendable, Equatable, LocalizedError {
    case pluginHostUnavailable
    case pluginUpdateInProgress
    case pluginAlreadyEnabled(String)
    case pluginNotEnabled(String)
    case noPendingPluginApproval
    case missingExposureSnapshot
    case sceneRevisionChanged(expected: UInt64, actual: UInt64)
    /// The plugin declares components but returned something other than a read payload.
    case unexpectedComponentDeclarationResult(String)
    case invalidComponentDeclaration(String)
    /// The on-disk package no longer matches its stored authorization; the
    /// user must re-authorize the new build through the management flow.
    case pluginAuthorizationStale(String)

    public var errorDescription: String? {
        switch self {
        case .pluginHostUnavailable:
            return "The trusted GuavaPluginHost executable is unavailable. Rebuild or reinstall the Editor."
        case .pluginUpdateInProgress:
            return "Wait for the current plugin update to finish."
        case let .pluginAlreadyEnabled(id):
            return "Plugin '\(id)' is already enabled. Disable it before loading another version."
        case let .pluginNotEnabled(id):
            return "Plugin '\(id)' is not enabled."
        case .noPendingPluginApproval:
            return "No inspected plugin is waiting for approval."
        case .missingExposureSnapshot:
            return "The plugin plan is missing its capability exposure snapshot."
        case let .sceneRevisionChanged(expected, actual):
            return "The scene changed while preparing plugin data (expected \(expected), actual \(actual))."
        case let .unexpectedComponentDeclarationResult(id):
            return "Plugin capability '\(id)' must return a read payload of component descriptions."
        case let .invalidComponentDeclaration(id):
            return "Plugin '\(id)' declared components the host rejected. Its other capabilities stay enabled."
        case let .pluginAuthorizationStale(id):
            return "Plugin '\(id)' changed on disk since it was authorized. Review and authorize the new build in Settings, then enable it again."
        }
    }
}
