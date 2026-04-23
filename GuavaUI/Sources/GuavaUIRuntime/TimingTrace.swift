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
        ProcessInfo.processInfo.systemUptime
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