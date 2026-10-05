import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import RenderBackend
import SceneRuntime

struct DeveloperFrameTrendSummary: Equatable {
    var sampleCount: Int
    var firstSampleIndex: UInt64
    var lastSampleIndex: UInt64
    var averageObservedFPS: Double
    var averageWorkFPS: Double
    var averageWorkMs: Double
    var p95WorkMs: Double
    var maxWorkMs: Double
    var averagePacingGapMs: Double
    var maxPacingGapMs: Double
    var pacingDominatedSamples: Int
    var peakWorkSampleIndex: UInt64
    var maxDrawCallCount: Int
    var maxPassCount: Int
    var maxRenderBundleCount: Int
}

func makeDeveloperFrameTrendSummary(
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
    var maxRenderBundleCount = 0
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
        maxRenderBundleCount = max(maxRenderBundleCount, stats.renderBundleCount)
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
        maxRenderBundleCount: maxRenderBundleCount
    )
}
