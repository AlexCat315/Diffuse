import GuavaUIDevToolsProtocol
import Foundation

/// Holds rolling timing data and pushes it through the DevServer once per
/// host frame. The host runtime is responsible for calling `record(...)` —
/// the publisher does no instrumentation on its own.
public final class TimingPublisher: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((TimingFramePayload) -> Void)?

    /// Set by `DevTools` after the server starts.
    public var deliver: ((TimingFramePayload) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }

    private var frame: UInt64 = 0

    public init() {}

    public func record(layoutMs: Double,
                       drawMs: Double,
                       presentMs: Double,
                       totalMs: Double,
                       nodeCount: Int,
                       batchCount: Int) {
        let delivery: (((TimingFramePayload) -> Void), UInt64)? = lock.withLock {
            guard let callback else { return nil }
            frame &+= 1
            return (callback, frame)
        }
        guard let (deliver, frame) = delivery else { return }
        deliver(TimingFramePayload(
            frame: frame,
            layoutMs: layoutMs,
            drawMs: drawMs,
            presentMs: presentMs,
            totalMs: totalMs,
            nodeCount: nodeCount,
            batchCount: batchCount
        ))
    }
}
