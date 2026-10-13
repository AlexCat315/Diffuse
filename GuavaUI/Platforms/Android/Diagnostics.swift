import Foundation
import GuavaUIDevTools
import GuavaUIRuntime
import GuavaUICompose

/// The socket queue only enqueues work; it never reads the scene or renderer.
private final class DiagnosticsInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@MainActor @Sendable () -> Void] = []
    private let schedule: @Sendable () -> Void
    init(schedule: @escaping @Sendable () -> Void) { self.schedule = schedule }
    func enqueue(_ operation: @escaping @MainActor @Sendable () -> Void) {
        let wake = lock.withLock { work.append(operation); return work.count == 1 }
        if wake { schedule() }
    }
    func take() -> [@MainActor @Sendable () -> Void] {
        lock.withLock { let pending = work; work.removeAll(); return pending }
    }
}

@MainActor
final class AndroidDiagnostics {
    private let inbox: DiagnosticsInbox
    private let tools: DevTools
    private var frameStart = DispatchTime.now().uptimeNanoseconds
    private var layoutMs = 0.0
    private var drawMs = 0.0

    init(config: DevToolsConfig, tree: NodeTree, graph: ViewGraph,
         schedule: @escaping @Sendable () -> Void, invalidate: @escaping @MainActor () -> Void) throws {
        let inbox = DiagnosticsInbox(schedule: schedule)
        self.inbox = inbox
        tools = DevTools(config: config, tree: tree, renderTree: graph.renderTree)
        tools.stateRegistry = graph.stateRegistry
        tools.server.host.execute = { operation in inbox.enqueue(operation) }
        tools.onSelectionChanged = invalidate
        try tools.start()
    }
    func drain() { for operation in inbox.take() { operation() } }
    func intercept(_ event: InputEvent) -> Bool { tools.interceptInput(event) }
    func overlay(into list: DrawList) { tools.drawInspectionOverlay(into: list) }
    func beginFrame() { frameStart = DispatchTime.now().uptimeNanoseconds }
    func prepared(layout: Double, draw: Double) { layoutMs = layout; drawMs = draw }
    func presented(tree: NodeTree, list: DrawList) {
        let total = Double(DispatchTime.now().uptimeNanoseconds - frameStart) / 1_000_000
        tools.notifyTreeChanged()
        tools.timing.record(layoutMs: layoutMs, drawMs: drawMs, presentMs: max(0, total - layoutMs - drawMs),
            totalMs: total, nodeCount: tree.nodeCount, batchCount: list.batches.count)
        tools.notifyFrameFinished()
    }
    func stop() { tools.stop() }
}
