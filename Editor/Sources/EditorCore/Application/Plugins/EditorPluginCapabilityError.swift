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
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat


public enum EditorPluginCapabilityError: Error, Sendable, Equatable, LocalizedError {
    case pluginHostUnavailable
    case pluginAlreadyEnabled(String)
    case pluginNotEnabled(String)
    case noPendingPluginApproval
    case missingExposureSnapshot
    case sceneRevisionChanged(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .pluginHostUnavailable:
            return "The trusted GuavaPluginHost executable is unavailable. Rebuild or reinstall the Editor."
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
        }
    }
}
