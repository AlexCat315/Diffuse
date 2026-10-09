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

extension EditorApplication {
    struct ContextMemoryInitialization {
        var store: ContextMemoryStore?
        var warning: String?
    }

    static func initializeContextMemory(at storageURL: URL) -> ContextMemoryInitialization {
        do {
            return ContextMemoryInitialization(
                store: try ContextMemoryStore(storageURL: storageURL),
                warning: nil
            )
        } catch {
            let originalError = error
            guard FileManager.default.fileExists(atPath: storageURL.path) else {
                return ContextMemoryInitialization(
                    store: nil,
                    warning: "Context memory could not be initialized: \(originalError)"
                )
            }
            let quarantineURL = storageURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: storageURL, to: quarantineURL)
                let replacement = try ContextMemoryStore(storageURL: storageURL)
                return ContextMemoryInitialization(
                    store: replacement,
                    warning: "The unreadable file was moved to \(quarantineURL.lastPathComponent): \(originalError)"
                )
            } catch {
                return ContextMemoryInitialization(
                    store: nil,
                    warning: "Context memory is disabled because recovery failed: \(error); original error: \(originalError)"
                )
            }
        }
    }

    func flushContextMemoryBeforeShutdown() {
        guard let contextMemoryStore else { return }
        let setupTask = pendingAISetupTask
        let observationTask = pendingWorldObservationTask
        do {
            try waitForMCPCapabilityResult {
                await setupTask?.value
                await observationTask?.value
                try await contextMemoryStore.flush()
            }
            pendingAISetupTask = nil
            pendingWorldObservationTask = nil
        } catch {
            logConsole("Failed to persist AI context memory",
                       severity: .error,
                       detail: String(describing: error))
        }
    }

    func observeWorldEvents(_ events: [WorldEvent]) {
        guard !events.isEmpty else { return }
        let worldContext = self.aiWorldContext
        let session = session
        let previousTask = pendingWorldObservationTask
        pendingWorldObservationTask = Task {
            await previousTask?.value
            await worldContext.observe(events: events)
            if let session {
                await session.observe(events: events)
            }
        }
    }

    func readAIWorldEntityRecord(ref: String) -> WorldEntityRecord? {
        let semaphore = DispatchSemaphore(value: 0)
        let worldContext = self.aiWorldContext
        final class ReadState: @unchecked Sendable {
            var record: WorldEntityRecord?
        }
        let state = ReadState()
        Task {
            state.record = await worldContext.entityRecord(ref: ref)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 5) == .success else { return nil }
        return state.record
    }

    func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
