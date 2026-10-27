import Foundation
import NativeRHI
import RenderBackend

final class EditorRendererPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var sequence: UInt64 = 0
    func begin() -> UInt64 {
        lock.withLock { generation &+= 1; sequence = 0; task?.cancel(); task = nil; return generation }
    }
    func attach(_ task: Task<Void, Never>, generation: UInt64) {
        lock.withLock { if self.generation == generation { self.task = task } else { task.cancel() } }
    }
    func isCurrent(_ generation: UInt64) -> Bool { lock.withLock { self.generation == generation } }
    func accept(_ sequence: UInt64, generation: UInt64) -> Bool {
        lock.withLock {
            guard self.generation == generation, sequence > self.sequence else { return false }
            self.sequence = sequence; return true
        }
    }
    func finish(_ generation: UInt64) { lock.withLock { if self.generation == generation { task = nil } } }
    func cancel() -> Bool {
        lock.withLock { generation &+= 1; let active = task != nil; task?.cancel(); task = nil; return active }
    }
}

extension EditorApplication {
    public func cancelRendererPreparation() {
        guard subscriptions.rendererPreparation.cancel() else { return }
        store.dispatch(.setOperation(EditorOperation(id: "renderer-preparation", kind: .preparingRenderer,
            status: .cancelled, message: "Shader preparation cancelled")))
    }

    public func retryRendererPreparation() { prepareRendererAtLaunch() }

    func prepareRendererAtLaunch() {
        guard engine.renderDevice != nil else {
            engine.start(renderSurface: nil, enableViewportSurface: true)
            store.dispatch(.setConnected(true))
            return
        }
        let preparation = subscriptions.rendererPreparation
        let generation = preparation.begin()
        let settings = makeViewportRenderSettings(shadowsEnabled: store.state.shadows.enabled,
            shadingMode: store.state.viewport.shadingMode)
        store.dispatch(.setOperation(EditorOperation(id: "renderer-preparation", kind: .preparingRenderer,
            message: "Preparing shaders…")))
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { preparation.finish(generation) }
            do {
                let renderer = try await engine.prepareRenderer(enableViewportSurface: true, initialSettings: settings) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, preparation.accept(progress.sequence, generation: generation) else { return }
                        self.showRendererPreparation(progress)
                    }
                }
                try Task.checkCancellation()
                guard preparation.isCurrent(generation) else { return }
                engine.start(renderSurface: nil, enableViewportSurface: true, renderConsumer: renderer)
                queueTrackedRenderSettings(settings)
                store.dispatch(.setConnected(true))
                logConsole("Editor connected to runtime")
            } catch is CancellationError {
                if preparation.isCurrent(generation) {
                    store.dispatch(.setOperation(EditorOperation(id: "renderer-preparation", kind: .preparingRenderer,
                        status: .cancelled, message: "Shader preparation cancelled")))
                }
            } catch {
                guard preparation.isCurrent(generation) else { return }
                store.dispatch(.setOperation(EditorOperation(id: "renderer-preparation", kind: .preparingRenderer,
                    status: .failed, message: "Shader preparation failed")))
                logConsole("Shader preparation failed: \(error)", severity: .error)
            }
        }
        preparation.attach(task, generation: generation)
    }

    private func showRendererPreparation(_ progress: ResourcePreparationProgress) {
        let status: EditorOperationStatus
        switch progress.phase {
        case .preparing: status = .running
        case .finished: status = .succeeded
        case .cancelled: status = .cancelled
        case .failed: status = .failed
        }
        let detail = progress.currentStep
        store.dispatch(.setOperation(EditorOperation(id: "renderer-preparation", kind: .preparingRenderer,
            status: status, message: detail ?? "Preparing shaders…",
            completed: progress.completedSteps, total: progress.totalSteps ?? 0)))
    }
}
