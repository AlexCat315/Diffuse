import Foundation
import RenderBackend
import SceneRuntime

public struct DeveloperFrameTrendSummary: Codable, Sendable, Equatable {
    public let sampleCount: Int
    public let firstSampleIndex: UInt64
    public let lastSampleIndex: UInt64
    public let averageObservedFPS: Double
    public let averageWorkFPS: Double
    public let averageWorkMs: Double
    public let p95WorkMs: Double
    public let maxWorkMs: Double
    public let averagePacingGapMs: Double
    public let maxPacingGapMs: Double
    public let pacingDominatedSamples: Int
    public let peakWorkSampleIndex: UInt64
    public let maxDrawCallCount: Int
    public let maxPassCount: Int
    public let maxMeshBatchCount: Int
}

public func makeDeveloperFrameTrendSummary(
    history: [EditorFrameStatsHistorySample]
) -> DeveloperFrameTrendSummary? {
    guard !history.isEmpty else { return nil }

    var observedFPSTotal = 0.0
    var workFPSTotal = 0.0
    var workMsTotal = 0.0
    var pacingGapMsTotal = 0.0
    var maxPacingGapMs = 0.0
    var pacingDominatedSamples = 0
    var maxDrawCallCount = 0
    var maxPassCount = 0
    var maxMeshBatchCount = 0
    var peakWorkSample = history[0]
    var workMsValues: [Double] = []
    workMsValues.reserveCapacity(history.count)

    for sample in history {
        let stats = sample.stats
        observedFPSTotal += stats.fps
        workFPSTotal += stats.workFPS
        workMsTotal += stats.workMs
        pacingGapMsTotal += stats.pacingGapMs
        maxPacingGapMs = max(maxPacingGapMs, stats.pacingGapMs)
        if stats.isFramePacingDominated {
            pacingDominatedSamples += 1
        }
        if stats.workMs > peakWorkSample.stats.workMs {
            peakWorkSample = sample
        }
        maxDrawCallCount = max(maxDrawCallCount, stats.drawCallCount)
        maxPassCount = max(maxPassCount, stats.passCount)
        maxMeshBatchCount = max(maxMeshBatchCount, stats.meshBatchCount)
        workMsValues.append(stats.workMs)
    }

    let count = Double(history.count)
    return DeveloperFrameTrendSummary(
        sampleCount: history.count,
        firstSampleIndex: history[0].sampleIndex,
        lastSampleIndex: history[history.count - 1].sampleIndex,
        averageObservedFPS: observedFPSTotal / count,
        averageWorkFPS: workFPSTotal / count,
        averageWorkMs: workMsTotal / count,
        p95WorkMs: percentile(workMsValues, fraction: 0.95),
        maxWorkMs: peakWorkSample.stats.workMs,
        averagePacingGapMs: pacingGapMsTotal / count,
        maxPacingGapMs: maxPacingGapMs,
        pacingDominatedSamples: pacingDominatedSamples,
        peakWorkSampleIndex: peakWorkSample.sampleIndex,
        maxDrawCallCount: maxDrawCallCount,
        maxPassCount: maxPassCount,
        maxMeshBatchCount: maxMeshBatchCount
    )
}
