import Foundation
import RenderBackend
import SceneRuntime

public func formatFPS(_ fps: Double) -> String {
    if fps <= 0 { return "--" }
    if fps >= 1000 { return "---" }
    return String(format: "%.0f", fps)
}

public func formatMs(_ ms: Double) -> String {
    if ms <= 0 { return "--ms" }
    if ms < 10 { return String(format: "%.2fms", ms) }
    if ms < 100 { return String(format: "%.1fms", ms) }
    return String(format: "%.0fms", ms)
}

public func formatNs(_ ns: UInt64) -> String {
    if ns == 0 { return "--" }
    let ms = Double(ns) / 1_000_000.0
    if ms < 0.01 { return String(format: "%.3fms", ms) }
    if ms < 10 { return String(format: "%.2fms", ms) }
    if ms < 100 { return String(format: "%.1fms", ms) }
    return String(format: "%.0fms", ms)
}

public func formatByteCount(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 B" }
    if bytes < 1_024 { return "\(bytes) B" }
    let kib = Double(bytes) / 1_024
    if kib < 1_024 { return String(format: "%.1f KiB", kib) }
    return String(format: "%.1f MiB", kib / 1_024)
}

public func formatSignedMs(_ ms: Double) -> String {
    guard ms.isFinite else { return "--ms" }
    if ms == 0 { return "0.00ms" }
    let prefix = ms > 0 ? "+" : "-"
    return "\(prefix)\(formatMs(abs(ms)))"
}

public func gpuParticleWorkgroupTotal(_ stats: RenderFrameStats) -> Int {
    stats.gpuParticleSimulationDispatchWorkgroups
        + stats.gpuParticleSortDispatchWorkgroups
        + stats.gpuParticleInstanceDispatchWorkgroups
        + stats.gpuParticleCullDispatchWorkgroups
}

public func particleAverageBatchSize(_ summary: ParticleRenderSummary) -> Double {
    guard summary.batchCount > 0 else { return 0 }
    return Double(summary.particleCount) / Double(summary.batchCount)
}

public func particleSortPaddingOverhead(_ stats: RenderFrameStats) -> Double {
    guard stats.gpuParticleSortPaddedItemCount > 0,
          stats.gpuParticleSortPaddedItemCount >= stats.gpuParticleSortItemCount
    else { return 0 }
    let padding = stats.gpuParticleSortPaddedItemCount - stats.gpuParticleSortItemCount
    return Double(padding) / Double(stats.gpuParticleSortPaddedItemCount)
}

public func particleSortPaddingOverhead(_ sample: EditorParticleDiagnosticsSample) -> Double {
    guard sample.gpuSortPaddedItemCount > 0,
          sample.gpuSortPaddedItemCount >= sample.gpuSortItemCount
    else { return 0 }
    let padding = sample.gpuSortPaddedItemCount - sample.gpuSortItemCount
    return Double(padding) / Double(sample.gpuSortPaddedItemCount)
}

public func percentile(_ values: [Double], fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let clampedFraction = min(max(fraction, 0), 1)
    let sortedValues = values.sorted()
    let rawIndex = clampedFraction * Double(sortedValues.count - 1)
    let index = Int(rawIndex.rounded(.up))
    return sortedValues[min(max(index, 0), sortedValues.count - 1)]
}

public func formatPercent(_ numerator: Int, _ denominator: Int) -> String {
    guard denominator > 0 else { return "--" }
    let percent = Double(numerator) / Double(denominator) * 100
    if percent < 10 { return String(format: "%.1f%%", percent) }
    return String(format: "%.0f%%", percent)
}

public func formatPercentFraction(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    let percent = value * 100
    if percent < 10 { return String(format: "%.1f%%", percent) }
    return String(format: "%.0f%%", percent)
}

public func formatBudget(_ used: Int, _ limit: Int) -> String {
    limit > 0 ? "\(used)/\(limit)" : "\(used)/unlimited"
}

public func formatDecimal(_ value: Double) -> String {
    guard value.isFinite else { return "--" }
    if value >= 10 { return String(format: "%.0f", value) }
    return String(format: "%.1f", value)
}

public func formatScale(_ value: Float) -> String {
    guard value.isFinite else { return "--" }
    return String(format: "%.2f", value)
}

public func cpuMs(_ stats: EditorFrameStats) -> Double {
    stats.cpuWorkSeconds * 1000
}

private func budgetStatus(frameMs: Double, targetMs: Double) -> String {
    guard frameMs > 0 else { return "--" }
    if frameMs <= targetMs { return "OK" }
    return "+\(formatMs(frameMs - targetMs))"
}

public func bottleneck(_ stats: EditorFrameStats) -> String {
    let cpu = cpuMs(stats)
    let gpu = stats.gpuPresentSeconds * 1000
    guard stats.workMs > 0 else { return "--" }
    if cpu <= 0, gpu <= 0 { return "Frame pacing" }
    if stats.isFramePacingDominated {
        return "Frame pacing / idle"
    }
    if cpu > gpu * 1.25 { return "CPU" }
    if gpu > cpu * 1.25 { return "GPU / present" }
    return "Mixed"
}

private func averageDrawsPerPass(_ stats: EditorFrameStats) -> String {
    guard stats.passCount > 0 else { return "--" }
    let average = Double(stats.drawCallCount) / Double(stats.passCount)
    if average < 10 { return String(format: "%.1f", average) }
    return String(format: "%.0f", average)
}

private func selectedFrameSample(history: [EditorFrameStatsHistorySample],
                                 selectedSampleIndex: UInt64?) -> EditorFrameStatsHistorySample? {
    if let selectedSampleIndex,
       let sample = history.first(where: { $0.sampleIndex == selectedSampleIndex }) {
        return sample
    }
    return history.last
}

public func frameBudgetGlyph(_ stats: EditorFrameStats) -> String {
    if stats.isFramePacingDominated { return "P" }
    if stats.workMs > 33.3 { return "!" }
    if stats.workMs > 16.7 { return "*" }
    return "."
}

