import Foundation
import RenderBackend
import SceneRuntime

/// Buffers render-thread readbacks for one scene generation. Replacing or
/// restoring the authored scene invalidates both queued and in-flight feedback.
final class ParticleFeedbackInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [GPUParticleSimulationEventSnapshot] = []
    private var generation: UInt64 = 0
    private var lastReport = ParticleSimulationEventApplyReport.empty

    var report: ParticleSimulationEventApplyReport {
        lock.lock()
        defer { lock.unlock() }
        return lastReport
    }

    func makeHandler() -> @Sendable ([GPUParticleSimulationEventSnapshot]) -> Void {
        lock.lock()
        let currentGeneration = generation
        lock.unlock()
        return { [weak self] snapshots in
            guard !snapshots.isEmpty, let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.generation == currentGeneration {
                self.pending.append(contentsOf: snapshots)
            }
        }
    }

    func drain() -> [GPUParticleSimulationEventSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let snapshots = pending
        pending.removeAll(keepingCapacity: true)
        return snapshots
    }

    func record(_ report: ParticleSimulationEventApplyReport) {
        lock.lock()
        defer { lock.unlock() }
        lastReport = report
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
        lastReport = .empty
    }
}
