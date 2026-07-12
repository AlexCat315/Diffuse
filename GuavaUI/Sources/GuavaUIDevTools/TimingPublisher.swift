import Foundation

public struct TimingFramePayload: Codable {
    public var frame: UInt64
    /// Time spent on layout this frame, in milliseconds.
    public var layoutMs: Double
    /// Time spent encoding the draw list this frame, in milliseconds.
    public var drawMs: Double
    /// Time spent submitting commands and presenting this frame, in ms.
    public var presentMs: Double
    /// Total wall-clock duration of this frame, in milliseconds.
    public var totalMs: Double
    /// Number of nodes in the scene graph this frame.
    public var nodeCount: Int
    /// Number of draw batches emitted this frame.
    public var batchCount: Int
}

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
