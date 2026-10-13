import Foundation

/// Optional asynchronous GPU timing for queued submissions.
///
/// Backends that cannot timestamp leave the profile untouched; callers check
/// `Device.supportsGPUTimestamps` before attaching one. Results reach the profile
/// from the backend's completion thread once the GPU retires the work, so read
/// them after the sampled frames have retired rather than right after submit.
///
/// Values cover GPU execution only. Queue wait, swapchain acquire and present are
/// not included, and an unfinished marker is omitted rather than reported as zero.
public final class GPUTimestampProfile: @unchecked Sendable {
    /// One measured interval between two adjacent GPU timestamps.
    public struct Marker: Sendable, Equatable {
        public let label: String
        public let nanoseconds: UInt64

        public init(label: String, nanoseconds: UInt64) {
            self.label = label
            self.nanoseconds = nanoseconds
        }
    }

    private let lock = NSLock()
    private let markerLimit: Int
    private var markers: [Marker] = []
    private var completed = 0
    private var statusValue = "idle"

    /// Bounded so an unbounded session cannot grow the sample list for ever.
    public init(markerLimit: Int = 600) {
        self.markerLimit = max(0, markerLimit)
    }

    /// Why recording is or is not producing markers. `ok` means the backend is
    /// resolving queries; any other value names the gate that stopped it, which
    /// is the difference between "slow" and "not measured".
    public var status: String { lock.withLock { statusValue } }

    func note(_ status: String) { lock.withLock { statusValue = status } }

    func append(_ marker: Marker) {
        lock.withLock {
            completed += 1
            // Retention is bounded but the count is not, so a caller can tell a
            // complete report from one that stopped early.
            guard markers.count < markerLimit else { return }
            markers.append(marker)
        }
    }

    /// Markers retained so far, in completion order. Shorter than `sampleCount`
    /// once the limit was reached, which is how truncation becomes visible.
    public var recordedMarkers: [Marker] { lock.withLock { markers } }

    /// Total markers completed, including any not retained past `markerLimit`.
    public var sampleCount: Int { lock.withLock { completed } }

    public func reset() {
        lock.withLock {
            markers.removeAll(keepingCapacity: true)
            completed = 0
        }
    }
}

/// A backend able to timestamp GPU execution for the submissions it queues.
///
/// Conformance is optional so that backends without timestamp support keep their
/// existing submission path unchanged.
public protocol GPUTimestampRecording: AnyObject {
    /// The profile receiving results, or `nil` to record nothing. Setting it does
    /// no GPU work on its own; recording starts with the next submission.
    var gpuTimestampProfile: GPUTimestampProfile? { get set }
}
