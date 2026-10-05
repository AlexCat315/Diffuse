import EditorCore

struct DeveloperParticleTrendSummary: Equatable {
    var sampleCount: Int
    var firstSampleIndex: UInt64
    var lastSampleIndex: UInt64
    var averageLiveParticleCount: Double
    var maxLiveParticleCount: Int
    var peakLiveSampleIndex: UInt64
    var liveBudgetPressureSamples: Int
    var totalRequestedSpawnCount: Int
    var totalSpawnedParticleCount: Int
    var totalDroppedSpawnCount: Int
    var totalCapacityLimitedSpawnCount: Int
    var totalSpawnBudgetLimitedCount: Int
    var totalEventDroppedSpawnCount: Int
    var totalDroppedReadbackEventCount: Int
    var peakDropSampleIndex: UInt64
    var maxDroppedSpawnCount: Int
    var maxRequestedSpawnCount: Int
    var peakSpawnRequestSampleIndex: UInt64
    var maxCPURenderInstanceCount: Int
    var maxGPURenderInstanceCount: Int
    var maxGPUSimulationParticleCount: Int
    var maxGPUWorkgroupCount: Int
    var maxSortPaddingOverhead: Double
}

func makeDeveloperParticleTrendSummary(
    history: [EditorParticleDiagnosticsSample]
) -> DeveloperParticleTrendSummary? {
    guard !history.isEmpty else { return nil }

    var liveTotal = 0
    var liveBudgetPressureSamples = 0
    var totalRequested = 0
    var totalSpawned = 0
    var totalDropped = 0
    var totalCapacityDropped = 0
    var totalBudgetDropped = 0
    var totalEventDropped = 0
    var totalReadbackDropped = 0
    var peakLiveSample = history[0]
    var peakDropSample = history[0]
    var peakRequestSample = history[0]
    var maxCPURenderInstanceCount = 0
    var maxGPURenderInstanceCount = 0
    var maxGPUSimulationParticleCount = 0
    var maxGPUWorkgroupCount = 0
    var maxSortPaddingOverhead = 0.0

    for sample in history {
        liveTotal += sample.liveParticleCount
        if sample.liveParticleLimit > 0
            && Double(sample.liveParticleCount) / Double(sample.liveParticleLimit) >= 0.9 {
            liveBudgetPressureSamples += 1
        }
        totalRequested += sample.requestedSpawnCount
        totalSpawned += sample.spawnedParticleCount
        totalDropped += sample.droppedSpawnCount
        totalCapacityDropped += sample.capacityLimitedSpawnCount
        totalBudgetDropped += sample.spawnBudgetLimitedCount
        totalEventDropped += sample.eventDroppedSpawnCount
        totalReadbackDropped += sample.droppedReadbackEventCount
        if sample.liveParticleCount > peakLiveSample.liveParticleCount {
            peakLiveSample = sample
        }
        if sample.droppedSpawnCount > peakDropSample.droppedSpawnCount {
            peakDropSample = sample
        }
        if sample.requestedSpawnCount > peakRequestSample.requestedSpawnCount {
            peakRequestSample = sample
        }
        maxCPURenderInstanceCount = max(maxCPURenderInstanceCount, sample.cpuRenderInstanceCount)
        maxGPURenderInstanceCount = max(maxGPURenderInstanceCount, sample.gpuRenderInstanceCount)
        maxGPUSimulationParticleCount = max(maxGPUSimulationParticleCount, sample.gpuSimulationParticleCount)
        maxGPUWorkgroupCount = max(maxGPUWorkgroupCount, sample.gpuWorkgroupCount)
        maxSortPaddingOverhead = max(maxSortPaddingOverhead, particleSortPaddingOverhead(sample))
    }

    return DeveloperParticleTrendSummary(
        sampleCount: history.count,
        firstSampleIndex: history[0].sampleIndex,
        lastSampleIndex: history[history.count - 1].sampleIndex,
        averageLiveParticleCount: Double(liveTotal) / Double(history.count),
        maxLiveParticleCount: peakLiveSample.liveParticleCount,
        peakLiveSampleIndex: peakLiveSample.sampleIndex,
        liveBudgetPressureSamples: liveBudgetPressureSamples,
        totalRequestedSpawnCount: totalRequested,
        totalSpawnedParticleCount: totalSpawned,
        totalDroppedSpawnCount: totalDropped,
        totalCapacityLimitedSpawnCount: totalCapacityDropped,
        totalSpawnBudgetLimitedCount: totalBudgetDropped,
        totalEventDroppedSpawnCount: totalEventDropped,
        totalDroppedReadbackEventCount: totalReadbackDropped,
        peakDropSampleIndex: peakDropSample.sampleIndex,
        maxDroppedSpawnCount: peakDropSample.droppedSpawnCount,
        maxRequestedSpawnCount: peakRequestSample.requestedSpawnCount,
        peakSpawnRequestSampleIndex: peakRequestSample.sampleIndex,
        maxCPURenderInstanceCount: maxCPURenderInstanceCount,
        maxGPURenderInstanceCount: maxGPURenderInstanceCount,
        maxGPUSimulationParticleCount: maxGPUSimulationParticleCount,
        maxGPUWorkgroupCount: maxGPUWorkgroupCount,
        maxSortPaddingOverhead: maxSortPaddingOverhead
    )
}