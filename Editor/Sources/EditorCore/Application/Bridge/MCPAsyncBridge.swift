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



private enum MCPAsyncBridgeError: Error, CustomStringConvertible {
    case timedOut
    case missingResult

    var description: String {
        switch self {
        case .timedOut: return "asynchronous editor operation timed out"
        case .missingResult: return "asynchronous editor operation returned no result"
        }
    }
}

private final class MCPAsyncResultBox<Value: Sendable>: @unchecked Sendable {
    var result: Result<Value, Error>?
}

/// The editor bridge is intentionally synchronous on its local TCP boundary.
/// Capability authority lives in an actor, so only the small actor operation is
/// awaited here; scene reads and transaction preparation remain on the editor
/// queue after this function returns.
func waitForMCPCapabilityResult<Value: Sendable>(
    timeout: TimeInterval = 5,
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = MCPAsyncResultBox<Value>()
    Task {
        do {
            box.result = .success(try await operation())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        throw MCPAsyncBridgeError.timedOut
    }
    guard let result = box.result else { throw MCPAsyncBridgeError.missingResult }
    return try result.get()
}
