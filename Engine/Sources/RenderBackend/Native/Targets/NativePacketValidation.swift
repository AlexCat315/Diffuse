import NativeRHI
import SceneRuntime
import SIMDCompat

/// Validate supported scene features before allocating resources or acquiring a drawable.
enum NativePacketValidation {
    static func validate(_ packet: RenderPacket) throws -> RenderCameraMatrices {
        guard packet.drawableSize.width > 0, packet.drawableSize.height > 0,
              packet.drawableSize.width <= ViewportTargetAllocation.maxDimension,
              packet.drawableSize.height <= ViewportTargetAllocation.maxDimension,
              !packet.renderSettings.enableEditorGrid || packet.renderSettings.editorGridSpacing.isFinite else { throw RHIError.invalidArgument("native viewport must be nonempty") }
        guard [.r1MeshCamera,.r2MultiObjectDepth,.r3ViewportInterop,.r4LightingPBRShadow,.r5PostProcess].contains(packet.renderSettings.stage) else {
            throw RHIError.unsupportedFeature("unsupported native scene stage")
        }
        try validateSimulation(packet)
        let settings = packet.renderSettings
        let style = settings.stylizedCharacterStyle
        if settings.enableStylizedCharacterShading {
            let values = [style.toonThresholds,style.toonLevels,style.inkWashColor,
                SIMD4(style.paperGrainStrength,style.rimStrength,style.materialBiasStrength,style.outlineWidth)]
            guard values.allSatisfy({ vector in (0..<4).allSatisfy { vector[$0].isFinite } }) else {
                throw RHIError.invalidArgument("non-finite stylized input")
            }
        }
        guard settings.stage == .r5PostProcess || !(settings.enableSSAO || settings.enableSSR || settings.enableTAA || settings.enableBloom || settings.enableFXAA) else {
            throw RHIError.unsupportedFeature("post effects require the r5 stage")
        }
        let scene = packet.scene
        guard scene.particles.count <= Int(UInt32.max), scene.particles.allSatisfy({ particle in
            GPUParticleInstance(particle: particle).isFinite
        }) else { throw RHIError.invalidArgument("non-finite or oversized particle input") }
        guard finite(scene.camera.eye), finite(scene.camera.target), finite(scene.camera.up),
              finite(scene.environment.ambientColor), scene.environment.ambientIntensity.isFinite,
              scene.environment.ambientIntensity >= 0, scene.environment.exposure.isFinite, scene.environment.exposure >= 0,
              scene.lights.allSatisfy({ finite($0.position) && finite($0.direction) && finite($0.color)
                && $0.intensity.isFinite && $0.intensity >= 0 && $0.range.isFinite && $0.range >= 0
                && $0.spotInnerAngleRadians.isFinite && $0.spotOuterAngleRadians.isFinite }),
              packet.renderSettings.shadowSettings.depthBias.isFinite,
              packet.renderSettings.shadowSettings.strength.isFinite,
              packet.renderSettings.shadowSettings.directionalCascadeSplitLambda.isFinite else {
            throw RHIError.invalidArgument("non-finite or negative native lighting input")
        }
        let matrices = RenderCameraMatrices.make(scene: packet.scene, drawableSize: packet.drawableSize)
        guard Self.finite(matrices.viewProjection), packet.scene.environment.exposure.isFinite,
              packet.scene.instances.allSatisfy({ Self.finite($0.transform) }) else {
            throw RHIError.invalidArgument("non-finite camera or instance transform")
        }
        for instance in packet.scene.instances {
            guard finite(instance.colorTint), instance.material.alphaCutoff?.isFinite != false,
                  instance.material.baseColorFactor.x.isFinite, instance.material.baseColorFactor.y.isFinite,
                  instance.material.baseColorFactor.z.isFinite, instance.material.baseColorFactor.w.isFinite else {
                throw RHIError.invalidArgument("non-finite material color")
            }
        }
        guard packet.jointPaletteMap.palettes.values.allSatisfy({ palette in
            palette.matrices.count <= Int(UInt32.max) && palette.matrices.allSatisfy(Self.finite)
        }) else { throw RHIError.invalidArgument("non-finite or oversized joint palette") }
        return matrices
    }
    private static func finite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }
    }
    private static func finite(_ vector: SIMD3<Float>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
    private static func validateSimulation(_ packet: RenderPacket) throws {
        guard Float(packet.deltaTime).isFinite, Float(packet.simulationTimeSeconds).isFinite else {
            throw RHIError.invalidArgument("non-finite particle simulation time")
        }
        var emitters = Set<UInt64>()
        var instances = packet.scene.particles.count
        for batch in packet.scene.particleSimulationBatches where batch.plan.usesGPU && batch.particleCount > 0 {
            guard batch.plan.particleCapacity > 0, batch.plan.particleCapacity <= GPUParticleSimulationUniforms.maximumExactParticleCount,
                  [batch.simulationSpeed,batch.noiseStrength,batch.noiseScale,batch.noiseSpeed,
                    batch.vectorFieldStrength,batch.vectorFieldScale,batch.vectorFieldScrollSpeed,
                    batch.forceRadius,batch.forceStrength,batch.forceFalloff,batch.collisionPlaneY,
                    batch.collisionRestitution,batch.collisionDamping].allSatisfy(\.isFinite),
                  finite(batch.worldTransform),
                  GPUParticleSimulationUniforms(batch: batch,deltaTime: Float(packet.deltaTime)*batch.simulationSpeed,
                    elapsedTime: Float(packet.simulationTimeSeconds),dispatchCount: batch.particleCount,eventCapacity: batch.plan.particleCapacity*2).isFinite,
                  batch.particles.allSatisfy({ GPUParticleSimulationState(particle: $0).isFinite }),
                  batch.spawnParticles.allSatisfy({ GPUParticleSimulationState(particle: $0).isFinite }) else {
                throw RHIError.invalidArgument("non-finite or oversized particle simulation input")
            }
            if let emitter = batch.emitterEntity?.rawValue, !emitters.insert(emitter).inserted {
                throw RHIError.invalidArgument("duplicate particle simulation emitter")
            }
            if batch.renderOnGPU {
                try validateParticleRendering(batch)
                let (count,overflow) = batch.renderParticleCount.multipliedReportingOverflow(by: batch.renderInstanceMultiplier)
                let (total,additionOverflow) = instances.addingReportingOverflow(count)
                guard !overflow, !additionOverflow, total <= GPUParticleSimulationUniforms.maximumExactParticleCount else {
                    throw RHIError.invalidArgument("simulated particle instance count exceeds the Float32 ABI")
                }
                instances = total
            }
        }
    }
    private static func validateParticleRendering(_ batch: RenderParticleSimulationBatch) throws {
        let limit = GPUParticleSimulationUniforms.maximumExactParticleCount
        let (frames,overflow) = batch.textureSheetColumns.multipliedReportingOverflow(by: batch.textureSheetRows)
        let appearance = GPUParticleAppearanceData(batch: batch)
        guard batch.trailSegments >= 0, batch.trailSegments < limit,
              [batch.textureSheetColumns,batch.textureSheetRows,batch.textureSheetFrameCount].allSatisfy({ $0 > 0 && $0 <= limit }),
              [batch.textureSheetStartFrame,batch.textureSheetFrameRandomness].allSatisfy({ $0 >= 0 && $0 <= limit }),
              !overflow, frames <= Int(UInt32.max),
              [batch.startSize,batch.endSize,batch.textureSheetFrameRate,batch.velocityStretchScale,batch.velocityStretchMax,
                batch.renderAlphaScale,batch.trailLength,batch.trailEndSizeScale,batch.trailEndAlphaScale].allSatisfy(\.isFinite),
              GPUParticleSimulationInstanceUniforms(batch: batch,baseInstance: 0,appearance: appearance).isFinite,
              appearance.isFinite else { throw RHIError.invalidArgument("non-finite or oversized simulated-particle rendering input") }
    }
}
