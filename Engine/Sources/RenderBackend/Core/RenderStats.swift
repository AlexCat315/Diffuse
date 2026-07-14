import Foundation

public enum GPUParticleSimulationEventTrigger: UInt32, Sendable, Equatable {
    case unknown = 0
    case collision = 1
    case death = 2

    public init(rawTrigger: UInt32) {
        self = GPUParticleSimulationEventTrigger(rawValue: rawTrigger) ?? .unknown
    }
}

public struct GPUParticleSimulationEventRecord: Sendable, Equatable {
    public var trigger: GPUParticleSimulationEventTrigger
    public var sourceIndex: UInt32
    public var position: SIMD3<Float>
    public var lifetime: Float
    public var velocity: SIMD3<Float>
    public var age: Float
    public var generation: UInt8
    public var appearanceIndex: UInt16

    public init(trigger: GPUParticleSimulationEventTrigger,
                sourceIndex: UInt32,
                position: SIMD3<Float>,
                lifetime: Float,
                velocity: SIMD3<Float>,
                age: Float,
                generation: UInt8 = 0,
                appearanceIndex: UInt16 = 0) {
        self.trigger = trigger
        self.sourceIndex = sourceIndex
        self.position = position
        self.lifetime = lifetime
        self.velocity = velocity
        self.age = age
        self.generation = generation
        self.appearanceIndex = appearanceIndex
    }
}

public struct GPUParticleSimulationEventSnapshot: Sendable, Equatable {
    public var slot: Int
    public var emitterRawValue: UInt64?
    public var eventCapacity: Int
    public var totalEventCount: Int
    public var droppedEventCount: Int
    public var records: [GPUParticleSimulationEventRecord]
    public var aliveParticleCount: Int
    public var expiredParticleCount: Int
    public var collisionEventCount: Int
    public var gpuSpawnedParticleCount: Int
    public var gpuDroppedSpawnCount: Int
    public var compactedParticleCount: Int

    public init(slot: Int,
                emitterRawValue: UInt64?,
                eventCapacity: Int,
                totalEventCount: Int,
                droppedEventCount: Int,
                records: [GPUParticleSimulationEventRecord],
                aliveParticleCount: Int = 0,
                expiredParticleCount: Int = 0,
                collisionEventCount: Int = 0,
                gpuSpawnedParticleCount: Int = 0,
                gpuDroppedSpawnCount: Int = 0,
                compactedParticleCount: Int = 0) {
        self.slot = max(0, slot)
        self.emitterRawValue = emitterRawValue
        self.eventCapacity = max(0, eventCapacity)
        self.totalEventCount = max(0, totalEventCount)
        self.droppedEventCount = max(0, droppedEventCount)
        self.records = records
        self.aliveParticleCount = max(0, aliveParticleCount)
        self.expiredParticleCount = max(0, expiredParticleCount)
        self.collisionEventCount = max(0, collisionEventCount)
        self.gpuSpawnedParticleCount = max(0, gpuSpawnedParticleCount)
        self.gpuDroppedSpawnCount = max(0, gpuDroppedSpawnCount)
        self.compactedParticleCount = max(0, compactedParticleCount)
    }
}

public struct RenderFrameStats: Sendable {
    public var frameIndex: Int
    public var passCount: Int
    public var drawCallCount: Int
    public var passDrawCallCounts: [RenderPassKind: Int]
    public var renderBundleCount: Int
    public var renderBundleParallelJobs: Int
    public var gpuParticleSimulationBatchCount: Int
    public var gpuParticleSimulationParticleCount: Int
    public var gpuParticleSimulationDispatchWorkgroups: Int
    public var gpuParticleSortPassCount: Int
    public var gpuParticleSortItemCount: Int
    public var gpuParticleSortPaddedItemCount: Int
    public var gpuParticleSortDispatchWorkgroups: Int
    public var gpuParticleInstanceDispatchWorkgroups: Int
    public var gpuParticleSimulationEventCapacity: Int
    public var gpuParticleSimulationEventBufferBytes: Int
    public var gpuParticleRenderInstanceCount: Int
    public var gpuParticleIndirectDrawCount: Int
    public var gpuParticleCullBatchCount: Int
    public var gpuParticleCullCandidateCount: Int
    public var gpuParticleCullDispatchWorkgroups: Int
    public var gpuParticleSimulationEncodeNS: UInt64
    public var deformableMeshCount: Int
    public var deformableVertexCount: Int
    public var deformableTriangleCount: Int
    public var deformableRejectedMeshCount: Int
    public var deformableUploadedBytes: UInt64
    public var deformableUploadNS: UInt64
    public var shadowedLightCount: Int
    public var shadowTileCount: Int
    public var shadowCascadeCount: Int
    public var shadowMapResolution: UInt32
    public var shadowAtlasResolution: UInt32
    public var activePasses: [RenderPassKind]
    public var settingsGeneration: UInt64
    public var cpuPrepareNS: UInt64
    public var cpuEncodeNS: UInt64
    public var cpuSubmitNS: UInt64
    public var cpuFrameTotalNS: UInt64
    public var cpuSkyboxEncodeNS: UInt64
    public var cpuBaseEncodeNS: UInt64
    public var cpuPostProcessEncodeNS: UInt64
    public var passEncodeNS: [RenderPassKind: UInt64]

    public init(
        frameIndex: Int = -1,
        passCount: Int = 0,
        drawCallCount: Int = 0,
        passDrawCallCounts: [RenderPassKind: Int] = [:],
        renderBundleCount: Int = 0,
        renderBundleParallelJobs: Int = 0,
        gpuParticleSimulationBatchCount: Int = 0,
        gpuParticleSimulationParticleCount: Int = 0,
        gpuParticleSimulationDispatchWorkgroups: Int = 0,
        gpuParticleSortPassCount: Int = 0,
        gpuParticleSortItemCount: Int = 0,
        gpuParticleSortPaddedItemCount: Int = 0,
        gpuParticleSortDispatchWorkgroups: Int = 0,
        gpuParticleInstanceDispatchWorkgroups: Int = 0,
        gpuParticleSimulationEventCapacity: Int = 0,
        gpuParticleSimulationEventBufferBytes: Int = 0,
        gpuParticleRenderInstanceCount: Int = 0,
        gpuParticleIndirectDrawCount: Int = 0,
        gpuParticleCullBatchCount: Int = 0,
        gpuParticleCullCandidateCount: Int = 0,
        gpuParticleCullDispatchWorkgroups: Int = 0,
        gpuParticleSimulationEncodeNS: UInt64 = 0,
        deformableMeshCount: Int = 0,
        deformableVertexCount: Int = 0,
        deformableTriangleCount: Int = 0,
        deformableRejectedMeshCount: Int = 0,
        deformableUploadedBytes: UInt64 = 0,
        deformableUploadNS: UInt64 = 0,
        shadowedLightCount: Int = 0,
        shadowTileCount: Int = 0,
        shadowCascadeCount: Int = 0,
        shadowMapResolution: UInt32 = 0,
        shadowAtlasResolution: UInt32 = 0,
        activePasses: [RenderPassKind] = [],
        settingsGeneration: UInt64 = 0,
        cpuPrepareNS: UInt64 = 0,
        cpuEncodeNS: UInt64 = 0,
        cpuSubmitNS: UInt64 = 0,
        cpuFrameTotalNS: UInt64 = 0,
        cpuSkyboxEncodeNS: UInt64 = 0,
        cpuBaseEncodeNS: UInt64 = 0,
        cpuPostProcessEncodeNS: UInt64 = 0,
        passEncodeNS: [RenderPassKind: UInt64] = [:]
    ) {
        self.frameIndex = frameIndex
        self.passCount = passCount
        self.drawCallCount = drawCallCount
        self.passDrawCallCounts = passDrawCallCounts
        self.renderBundleCount = renderBundleCount
        self.renderBundleParallelJobs = renderBundleParallelJobs
        self.gpuParticleSimulationBatchCount = gpuParticleSimulationBatchCount
        self.gpuParticleSimulationParticleCount = gpuParticleSimulationParticleCount
        self.gpuParticleSimulationDispatchWorkgroups = gpuParticleSimulationDispatchWorkgroups
        self.gpuParticleSortPassCount = gpuParticleSortPassCount
        self.gpuParticleSortItemCount = gpuParticleSortItemCount
        self.gpuParticleSortPaddedItemCount = gpuParticleSortPaddedItemCount
        self.gpuParticleSortDispatchWorkgroups = gpuParticleSortDispatchWorkgroups
        self.gpuParticleInstanceDispatchWorkgroups = gpuParticleInstanceDispatchWorkgroups
        self.gpuParticleSimulationEventCapacity = gpuParticleSimulationEventCapacity
        self.gpuParticleSimulationEventBufferBytes = gpuParticleSimulationEventBufferBytes
        self.gpuParticleRenderInstanceCount = gpuParticleRenderInstanceCount
        self.gpuParticleIndirectDrawCount = gpuParticleIndirectDrawCount
        self.gpuParticleCullBatchCount = gpuParticleCullBatchCount
        self.gpuParticleCullCandidateCount = gpuParticleCullCandidateCount
        self.gpuParticleCullDispatchWorkgroups = gpuParticleCullDispatchWorkgroups
        self.gpuParticleSimulationEncodeNS = gpuParticleSimulationEncodeNS
        self.deformableMeshCount = deformableMeshCount
        self.deformableVertexCount = deformableVertexCount
        self.deformableTriangleCount = deformableTriangleCount
        self.deformableRejectedMeshCount = deformableRejectedMeshCount
        self.deformableUploadedBytes = deformableUploadedBytes
        self.deformableUploadNS = deformableUploadNS
        self.shadowedLightCount = shadowedLightCount
        self.shadowTileCount = shadowTileCount
        self.shadowCascadeCount = shadowCascadeCount
        self.shadowMapResolution = shadowMapResolution
        self.shadowAtlasResolution = shadowAtlasResolution
        self.activePasses = activePasses
        self.settingsGeneration = settingsGeneration
        self.cpuPrepareNS = cpuPrepareNS
        self.cpuEncodeNS = cpuEncodeNS
        self.cpuSubmitNS = cpuSubmitNS
        self.cpuFrameTotalNS = cpuFrameTotalNS
        self.cpuSkyboxEncodeNS = cpuSkyboxEncodeNS
        self.cpuBaseEncodeNS = cpuBaseEncodeNS
        self.cpuPostProcessEncodeNS = cpuPostProcessEncodeNS
        self.passEncodeNS = passEncodeNS
    }
}
