import SceneRuntime
import SIMDCompat

// Shared binary layouts for the WGSL and Slang simulation programs.

struct GPUParticleSimulationUniforms {
    /// The shared WGSL/Slang ABI stores dispatch counts in Float32.
    static let maximumExactParticleCount = 1 << 24
    /// x: delta time, y: particle count, z: elapsed time, w: event buffer capacity.
    var time: SIMD4<Float>
    /// xyz: acceleration.
    var gravity: SIMD4<Float>
    /// x: strength, y: scale, z: speed, w: normalized seed phase.
    var noise: SIMD4<Float>
    /// xyz: vector-field bias direction, w: strength.
    var vectorFieldDirectionStrength: SIMD4<Float>
    /// x: scale, y: scroll speed, z: field mode (0 none, 1 uniform, 2 curl).
    var vectorFieldParams: SIMD4<Float>
    /// xyz: force center, w: force radius. Radius 0 means unbounded.
    var forceCenterRadius: SIMD4<Float>
    /// xyz: force axis, w: force mode (0 none, 1 radial, 2 vortex).
    var forceAxisMode: SIMD4<Float>
    /// x: force strength, y: force falloff.
    var forceParams: SIMD4<Float>
    /// x: collision mode (0 none, 1 local plane, 2 world plane), y: plane y, z: restitution, w: damping.
    var collisionParams: SIMD4<Float>
    var collisionToWorld: simd_float4x4
    var collisionToLocal: simd_float4x4
}

struct GPUParticleSimulationState {
    var positionLifetime: SIMD4<Float>
    var velocityAge: SIMD4<Float>
    var sizeRotation: SIMD4<Float>
    var color: SIMD4<Float>
    /// x: source generation, y: appearance index, z: texture frame seed, w: reserved.
    var params: SIMD4<UInt32>
}

struct GPUParticleSimulationEvent {
    /// xyz: event position, w: source lifetime.
    var positionLifetime: SIMD4<Float>
    /// xyz: event velocity, w: source age.
    var velocityAge: SIMD4<Float>
    /// x: trigger (1 collision, 2 death), y: source index,
    /// z: source generation, w: source appearance index.
    var params: SIMD4<UInt32>
}

struct GPUParticleSimulationMetadata {
    var aliveCount: UInt32 = 0
    var expiredCount: UInt32 = 0
    var collisionCount: UInt32 = 0
    var spawnedCount: UInt32 = 0
    var droppedSpawnCount: UInt32 = 0
    var appendCursor: UInt32 = 0
    var compactedCount: UInt32 = 0
    var eventCount: UInt32 = 0
    init(appendCursor: Int = 0) { self.appendCursor = UInt32(appendCursor) }
}

struct GPUParticleSpawnUniforms {
    /// x: requested spawn count, y: particle capacity.
    var params: SIMD4<UInt32>
}

struct GPUParticleStateMaintenanceUniforms {
    /// x: active simulation count, y: particle capacity.
    var params: SIMD4<UInt32>
}

extension GPUParticleSimulationState {
    var isFinite: Bool {
        func finite(_ value: SIMD4<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite }
        return finite(positionLifetime) && finite(velocityAge) && finite(sizeRotation) && finite(color)
    }
    init(particle: Particle) {
        positionLifetime = SIMD4(particle.position,particle.lifetime)
        velocityAge = SIMD4(particle.velocity,particle.age)
        sizeRotation = SIMD4(particle.size,particle.rotation,particle.angularVelocity,particle.sizeScale)
        color = particle.color
        params = SIMD4(UInt32(particle.generation),UInt32(particle.appearanceIndex),UInt32(particle.textureFrameSeed),0)
    }
}

extension GPUParticleSimulationUniforms {
    var isFinite: Bool {
        withUnsafeBytes(of: self) { $0.bindMemory(to: Float.self).allSatisfy(\.isFinite) }
    }
    init(batch: RenderParticleSimulationBatch, deltaTime: Float, elapsedTime: Float, dispatchCount: Int, eventCapacity: Int) {
        time = SIMD4(max(0,deltaTime),Float(dispatchCount),max(0,elapsedTime),Float(eventCapacity))
        gravity = SIMD4(batch.gravity,0)
        noise = SIMD4(max(0,batch.noiseStrength),max(0.0001,batch.noiseScale),max(0,batch.noiseSpeed),Float(batch.noiseSeed & 0xFFFF)*0.0001)
        vectorFieldDirectionStrength = SIMD4(batch.vectorFieldDirection,max(0,batch.vectorFieldStrength))
        let field: Float = switch batch.vectorFieldMode { case .none: 0; case .uniform: 1; case .curl: 2 }
        vectorFieldParams = SIMD4(max(0.0001,batch.vectorFieldScale),batch.vectorFieldScrollSpeed,field,0)
        forceCenterRadius = SIMD4(batch.forceCenter,max(0,batch.forceRadius))
        let force: Float = switch batch.forceMode { case .none: 0; case .radial: 1; case .vortex: 2 }
        forceAxisMode = SIMD4(batch.forceAxis,force)
        forceParams = SIMD4(batch.forceStrength,max(0,batch.forceFalloff),0,0)
        let collision: Float = switch batch.collisionMode { case .none: 0; case .localPlane: 1; case .worldPlane: 2 }
        collisionParams = SIMD4(collision,batch.collisionPlaneY,simd_clamp(batch.collisionRestitution,0,1),simd_clamp(batch.collisionDamping,0,1))
        collisionToWorld = batch.worldTransform
        collisionToLocal = batch.collisionMode == .worldPlane ? simd_inverse(batch.worldTransform) : matrix_identity_float4x4
    }
}

extension GPUParticleSimulationMetadata {
    func snapshot(slot: Int, emitter: UInt64?, capacity: Int, records: [GPUParticleSimulationEventRecord]) -> GPUParticleSimulationEventSnapshot {
        GPUParticleSimulationEventSnapshot(slot: slot,emitterRawValue: emitter,eventCapacity: capacity,
            totalEventCount: Int(eventCount),droppedEventCount: max(0,Int(eventCount)-capacity),records: records,
            aliveParticleCount: Int(aliveCount),expiredParticleCount: Int(expiredCount),collisionEventCount: Int(collisionCount),
            gpuSpawnedParticleCount: Int(spawnedCount),gpuDroppedSpawnCount: Int(droppedSpawnCount),compactedParticleCount: Int(compactedCount))
    }
}

extension GPUParticleSimulationEvent {
    var record: GPUParticleSimulationEventRecord {
        GPUParticleSimulationEventRecord(trigger: .init(rawTrigger: params.x),sourceIndex: params.y,
            position: SIMD3(positionLifetime.x,positionLifetime.y,positionLifetime.z),lifetime: positionLifetime.w,
            velocity: SIMD3(velocityAge.x,velocityAge.y,velocityAge.z),age: velocityAge.w,
            generation: UInt8(clamping: params.z),appearanceIndex: UInt16(clamping: params.w))
    }
}
