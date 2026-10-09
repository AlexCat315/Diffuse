import RenderBackend
import SceneRuntime
import SIMDCompat

public enum ParticleSimulationProbeScene {
    /// Resident simulation, sorting and conversion feed the full HDR post graph.
    /// CPU seed packets stay unchanged while the GPU advances both emitters.
    public static func packet(size: RenderDrawableSize, frame: Int = 0) -> RenderPacket {
        var packet = PostProbeScene.packet(size: size,frame: frame)
        packet.deltaTime = 1.0/60; packet.simulationTimeSeconds = Double(frame)/60
        packet.scene.particles = (0..<32).map { index in
            RenderParticle(position: SIMD3(Float(index)*0.3-4.8,3.2,3),size: 0.5,
                color: SIMD4(1.5,0.5,0.1,0.7),endColor: SIMD4(0.2,0.5,1.5,0),alignmentAxis: SIMD3(1,0.4,0),
                stretch: 2,startSize: 0.15,endSize: 0.02,shape: .ribbonSegment,blendMode: .additive)
        }
        packet.scene.particleSimulationBatches = [batch(emitter: 11,group: 37,frame: frame),batch(emitter: 22,group: 255,frame: frame)]
        if frame%2 == 1 { packet.scene.particleSimulationBatches.reverse() }
        return packet
    }
    private static func batch(emitter: UInt64, group: Int, frame: Int) -> RenderParticleSimulationBatch {
        let plan = ParticleEmitter(settings: .init {
            $0.emission.maxParticles = 1024
            $0.gpuSimulation.simulationBackend = .gpuRequired
            $0.gpuSimulation.workgroupSize = group
        }).gpuSimulationPlan
        let particles = (0..<1024).map { index -> Particle in
            let x = Float(index%32)*0.24-3.8, z = Float(index/32)*0.25-4
            return Particle(position: SIMD3(x,1.7+sin(x)*0.6,z),velocity: SIMD3(0.03,0.04,-0.02),
                age: Float(index%17)*0.02,lifetime: 10,sizeScale: 0.8,angularVelocity: 0.2,
                size: 0.13,color: SIMD4(0.5,0.8,1,0.6),appearanceIndex: UInt16(index%2),textureFrameSeed: UInt16(index))
        }
        var result = RenderParticleSimulationBatch(emitterEntity: EntityID(rawValue: emitter),plan: plan,
            particles: particles,gravity: .zero,renderOnGPU: true)
        result.simulationSpeed = 0.4
        result.noiseStrength = 0.02; result.noiseScale = 0.8; result.noiseSpeed = 0.4; result.noiseSeed = emitter
        result.vectorFieldMode = .curl; result.vectorFieldStrength = 0.02
        result.forceMode = .vortex; result.forceAxis = SIMD3(0,1,0); result.forceStrength = 0.01; result.forceFalloff = 0.5
        result.worldTransform.columns.3.x = emitter == 11 ? -2 : 2
        result.blendMode = emitter == 11 ? .alpha : .additive
        result.sortMode = emitter == 11 ? .distanceDescending : .oldestFirst
        result.renderAlignment = .velocity; result.velocityStretchScale = 2; result.velocityStretchMax = 3
        result.trailLength = 0.3; result.trailSegments = 2; result.trailEndSizeScale = 0.2; result.trailEndAlphaScale = 0.1
        result.appearancePalette = [.init(startSize: 0.15,endSize: 0.06,startColor: SIMD4(1.2,0.4,0.2,0.6),endColor: SIMD4(0.1,0.4,1,0.1)),
            .init(startSize: 0.12,endSize: 0.04,startColor: SIMD4(0.3,1,0.7,0.5),endColor: SIMD4(0.8,0.2,1,0.1))]
        result.sizeCurve = .easeOut; result.colorCurve = .easeInOut; result.usesAuthoredAppearance = true
        if frame > 0 && frame%48 == 0 {
            result.spawnParticles = [Particle(position: SIMD3(0,3,0),velocity: .zero,lifetime: 10,color: SIMD4(1,1,1,0.5))]
        }
        return result
    }
}
