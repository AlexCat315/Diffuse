import Foundation
import CoveLogging
import CoveUIRuntime

final class EditorSubscriptions {
    var events: PlatformEventBridge.SubscriptionToken?
    var settings: EditorStore.SubscriptionToken?
    let console = EditorLogCapture()
    let rendererPreparation = EditorRendererPreparation()
}

/// The writer only queues values. The editor's tick applies them to observable state.
final class EditorLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LogRecord] = []
    private var wake: (@Sendable () -> Void)?
    private var observation: LogObservation?
    init() {
        observation = LogSystem.observe { [weak self] record in
            guard record.metadata["editor_console"] != .string("direct"), let self else { return }
            let notify = lock.withLock {
                let wasEmpty = pending.isEmpty
                if pending.count == 200 { pending.removeFirst() }
                pending.append(record); return wasEmpty ? wake : nil
            }
            notify?()
        }
    }
    func setWake(_ wake: (@Sendable () -> Void)?) {
        let notify = lock.withLock { self.wake = wake; return pending.isEmpty ? nil : wake }; notify?()
    }
    func take() -> [LogRecord] { lock.withLock { let records = pending; pending.removeAll(keepingCapacity: true); return records } }
    func stop() { observation?.cancel(); observation = nil; lock.withLock { wake = nil; pending.removeAll() } }
}
