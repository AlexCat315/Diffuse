import Foundation
import CAndroidHost

/// Bounded CPU wall-clock samples. Queue and presentation may include waiting;
/// none of these values claim to measure GPU execution or displayed frames.
final class FrameTimings {
    enum Phase: String, CaseIterable {
        case scenePrepare, frameSlot, drawableAcquire, atlasUpload, commandRecord, queueSubmit, present
    }

    private let enabled: Bool
    private var samples = 0
    private var start: UInt64 = 0
    private var phases: [Phase: UInt64] = [:]

    init(enabled: Bool) { self.enabled = enabled }

    var isSampling: Bool { enabled && samples < 1200 }

    func begin() {
        guard isSampling else { return }
        start = DispatchTime.now().uptimeNanoseconds
        phases.removeAll(keepingCapacity: true)
    }

    func measure<T>(_ phase: Phase, _ operation: () throws -> T) rethrows -> T {
        guard isSampling else { return try operation() }
        let before = DispatchTime.now().uptimeNanoseconds
        defer { phases[phase, default: 0] += DispatchTime.now().uptimeNanoseconds - before }
        return try operation()
    }

    func finish(timestamp: UInt64, vertices: Int, indices: Int) {
        guard isSampling else { return }
        let total = DispatchTime.now().uptimeNanoseconds - start
        samples += 1
        let values = Phase.allCases.map { "\($0.rawValue)=\(milliseconds(phases[$0, default: 0]))ms" }.joined(separator: " ")
        guava_android_log("[timing] android.frame sample=\(samples) displayTime=\(timestamp) \(values) total=\(milliseconds(total))ms vertices=\(vertices) indices=\(indices)")
    }

    private func milliseconds(_ duration: UInt64) -> String {
        String(format: "%.3f", Double(duration) / 1_000_000)
    }
}
