import Dispatch
import Foundation

public struct TimingTrace {
    private struct Sample {
        let stage: String
        let milliseconds: Double
    }

    public let label: String
    private let startedAt: Double
    private var lastMark: Double
    private var samples: [Sample] = []

    public init(label: String) {
        let now = Self.now()
        self.label = label
        self.startedAt = now
        self.lastMark = now
    }

    @inline(__always)
    public static func now() -> Double {
        // High-resolution monotonic clock. `ProcessInfo.systemUptime` is backed
        // by `GetTickCount` on Windows (~16 ms granularity), which quantizes
        // every per-frame deltaTime to 0 or ~16 ms — corrupting animation /
        // physics timesteps and the editor FPS readout (and `timeBeginPeriod(1)`
        // does not help, it only affects `Sleep`). `DispatchTime` is
        // QueryPerformanceCounter-backed on Windows (mach_absolute_time on
        // Apple, CLOCK_MONOTONIC on Linux) and resolves to well under a
        // microsecond. The ns value fits exactly in a Double for >100 days of
        // uptime, and deltas keep sub-ns resolution well beyond that.
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public mutating func mark(_ stage: String) {
        let now = Self.now()
        samples.append(Sample(stage: stage, milliseconds: (now - lastMark) * 1000))
        lastMark = now
    }

    public func summary(extra: [String] = []) -> String {
        var parts = [label]
        for sample in samples {
            parts.append("\(sample.stage)=\(Self.format(sample.milliseconds))")
        }
        parts.append("total=\(Self.format((Self.now() - startedAt) * 1000))")
        parts.append(contentsOf: extra.filter { !$0.isEmpty })
        return parts.joined(separator: " ")
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.2fms", milliseconds)
    }
}