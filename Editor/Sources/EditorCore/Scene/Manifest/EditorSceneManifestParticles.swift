import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestParticleSubEmitter: Codable, Sendable, Equatable {
    public let trigger: ParticleSubEmitterTrigger
    public let burstCount: Int
    public let probability: Float
    public let maxDepth: Int
    public let inheritVelocity: Float
    public let lifetime: Float
    public let startVelocity: EditorSceneManifestVector3
    public let velocityRandomness: EditorSceneManifestVector3
    public let startSize: Float
    public let endSize: Float
    public let startColor: EditorSceneManifestVector4
    public let endColor: EditorSceneManifestVector4

    public init(_ rule: ParticleSubEmitter) {
        self.trigger = rule.trigger
        self.burstCount = rule.burstCount
        self.probability = rule.probability
        self.maxDepth = rule.maxDepth
        self.inheritVelocity = rule.inheritVelocity
        self.lifetime = rule.lifetime
        self.startVelocity = EditorSceneManifestVector3(rule.startVelocity)
        self.velocityRandomness = EditorSceneManifestVector3(rule.velocityRandomness)
        self.startSize = rule.startSize
        self.endSize = rule.endSize
        self.startColor = EditorSceneManifestVector4(rule.startColor)
        self.endColor = EditorSceneManifestVector4(rule.endColor)
    }

    var component: ParticleSubEmitter {
        ParticleSubEmitter(trigger: trigger,
                           burstCount: burstCount,
                           probability: probability,
                           maxDepth: maxDepth,
                           inheritVelocity: inheritVelocity,
                           lifetime: lifetime,
                           startVelocity: startVelocity.simdValue,
                           velocityRandomness: velocityRandomness.simdValue,
                           startSize: startSize,
                           endSize: endSize,
                           startColor: startColor.simdValue,
                           endColor: endColor.simdValue)
    }
}

public struct EditorSceneManifestParticleEmitter: Codable, Sendable, Equatable {
    public let isEmitting: Bool
    public let looping: Bool
    public let duration: Float
    public let simulationSpeed: Float
    public let prewarmTime: Float
    public let prewarmStep: Float
    public let emissionRate: Float
    public let emissionRateCurve: ParticleCurve
    public let distanceEmissionRate: Float
    public let distanceEmissionRateCurve: ParticleCurve
    public let burstCount: Int
    public let burstInterval: Float
    public let maxParticles: Int
    public let maxSpawnedParticlesPerFrame: Int
    public let maxRenderedParticles: Int
    public let lifetime: Float
    public let lifetimeRandomness: Float
    public let subEmitterTrigger: ParticleSubEmitterTrigger
    public let subEmitterBurstCount: Int
    public let subEmitterProbability: Float
    public let subEmitterMaxDepth: Int
    public let subEmitterInheritVelocity: Float
    public let subEmitterLifetime: Float
    public let subEmitterStartVelocity: EditorSceneManifestVector3
    public let subEmitterVelocityRandomness: EditorSceneManifestVector3
    public let subEmitterStartSize: Float
    public let subEmitterEndSize: Float
    public let subEmitterStartColor: EditorSceneManifestVector4
    public let subEmitterEndColor: EditorSceneManifestVector4
    public let subEmitters: [EditorSceneManifestParticleSubEmitter]
    public let originOffset: EditorSceneManifestVector3
    public let spawnRadius: Float
    public let emissionShape: ParticleEmissionShape
    public let boxHalfExtents: EditorSceneManifestVector3
    public let coneRadius: Float
    public let coneHeight: Float
    public let startVelocity: EditorSceneManifestVector3
    public let velocityRandomness: EditorSceneManifestVector3
    public let velocityInheritance: Float
    public let gravity: EditorSceneManifestVector3
    public let noiseStrength: Float
    public let noiseScale: Float
    public let noiseSpeed: Float
    public let forceMode: ParticleForceMode
    public let forceCenter: EditorSceneManifestVector3
    public let forceAxis: EditorSceneManifestVector3
    public let forceRadius: Float
    public let forceStrength: Float
    public let forceFalloff: Float
    public let vectorFieldMode: ParticleVectorFieldMode
    public let vectorFieldDirection: EditorSceneManifestVector3
    public let vectorFieldStrength: Float
    public let vectorFieldScale: Float
    public let vectorFieldScrollSpeed: Float
    public let collisionMode: ParticleCollisionMode
    public let simulationSpace: ParticleSimulationSpace
    public let simulationBackend: ParticleSimulationBackend
    public let gpuSimulationWorkgroupSize: Int
    public let collisionPlaneY: Float
    public let collisionRestitution: Float
    public let collisionDamping: Float
    public let startSize: Float
    public let endSize: Float
    public let sizeRandomness: Float
    public let startRotation: Float
    public let rotationRandomness: Float
    public let angularVelocity: Float
    public let angularVelocityRandomness: Float
    public let sizeCurve: ParticleCurve
    public let startColor: EditorSceneManifestVector4
    public let endColor: EditorSceneManifestVector4
    public let colorCurve: ParticleCurve
    public let blendMode: ParticleBlendMode
    public let renderMode: ParticleRenderMode
    public let sortMode: ParticleSortMode
    public let renderSortPriority: Int
    public let ribbonWidthScale: Float
    public let ribbonTailWidthScale: Float
    public let ribbonTailAlphaScale: Float
    public let ribbonMaxSegmentLength: Float
    public let ribbonJoinOverlapScale: Float
    public let ribbonSmoothingSegments: Int
    public let ribbonTextureTiling: Float
    public let ribbonTextureOffset: Float
    public let renderAlignment: ParticleRenderAlignment
    public let velocityStretchScale: Float
    public let velocityStretchMax: Float
    public let maxRenderDistance: Float
    public let renderDistanceFadeRange: Float
    public let renderLODStartDistance: Float
    public let renderLODEndDistance: Float
    public let renderLODMinParticleScale: Float
    public let renderBoundsMode: ParticleRenderBoundsMode
    public let renderBoundsRadius: Float
    public let textureAssetID: String?
    public let texturePath: String?
    public let textureSheetColumns: Int
    public let textureSheetRows: Int
    public let textureSheetFrameCount: Int
    public let textureSheetFrameRate: Float
    public let textureSheetPlaybackMode: ParticleTextureSheetPlaybackMode
    public let textureSheetStartFrame: Int
    public let textureSheetFrameRandomness: Int
    public let trailLength: Float
    public let trailSegments: Int
    public let trailEndSizeScale: Float
    public let trailEndAlphaScale: Float
    public let seed: UInt64
    public let moduleStack: ParticleModuleStack?

    public init(_ component: ParticleEmitter) {
        self.isEmitting = component.isEmitting
        self.looping = component.looping
        self.duration = component.duration
        self.simulationSpeed = component.simulationSpeed
        self.prewarmTime = component.prewarmTime
        self.prewarmStep = component.prewarmStep
        self.emissionRate = component.emissionRate
        self.emissionRateCurve = component.emissionRateCurve
        self.distanceEmissionRate = component.distanceEmissionRate
        self.distanceEmissionRateCurve = component.distanceEmissionRateCurve
        self.burstCount = component.burstCount
        self.burstInterval = component.burstInterval
        self.maxParticles = component.maxParticles
        self.maxSpawnedParticlesPerFrame = component.maxSpawnedParticlesPerFrame
        self.maxRenderedParticles = component.maxRenderedParticles
        self.lifetime = component.lifetime
        self.lifetimeRandomness = component.lifetimeRandomness
        self.subEmitterTrigger = component.subEmitterTrigger
        self.subEmitterBurstCount = component.subEmitterBurstCount
        self.subEmitterProbability = component.subEmitterProbability
        self.subEmitterMaxDepth = component.subEmitterMaxDepth
        self.subEmitterInheritVelocity = component.subEmitterInheritVelocity
        self.subEmitterLifetime = component.subEmitterLifetime
        self.subEmitterStartVelocity = EditorSceneManifestVector3(component.subEmitterStartVelocity)
        self.subEmitterVelocityRandomness = EditorSceneManifestVector3(component.subEmitterVelocityRandomness)
        self.subEmitterStartSize = component.subEmitterStartSize
        self.subEmitterEndSize = component.subEmitterEndSize
        self.subEmitterStartColor = EditorSceneManifestVector4(component.subEmitterStartColor)
        self.subEmitterEndColor = EditorSceneManifestVector4(component.subEmitterEndColor)
        self.subEmitters = component.subEmitters.map(EditorSceneManifestParticleSubEmitter.init)
        self.originOffset = EditorSceneManifestVector3(component.originOffset)
        self.spawnRadius = component.spawnRadius
        self.emissionShape = component.emissionShape
        self.boxHalfExtents = EditorSceneManifestVector3(component.boxHalfExtents)
        self.coneRadius = component.coneRadius
        self.coneHeight = component.coneHeight
        self.startVelocity = EditorSceneManifestVector3(component.startVelocity)
        self.velocityRandomness = EditorSceneManifestVector3(component.velocityRandomness)
        self.velocityInheritance = component.velocityInheritance
        self.gravity = EditorSceneManifestVector3(component.gravity)
        self.noiseStrength = component.noiseStrength
        self.noiseScale = component.noiseScale
        self.noiseSpeed = component.noiseSpeed
        self.forceMode = component.forceMode
        self.forceCenter = EditorSceneManifestVector3(component.forceCenter)
        self.forceAxis = EditorSceneManifestVector3(component.forceAxis)
        self.forceRadius = component.forceRadius
        self.forceStrength = component.forceStrength
        self.forceFalloff = component.forceFalloff
        self.vectorFieldMode = component.vectorFieldMode
        self.vectorFieldDirection = EditorSceneManifestVector3(component.vectorFieldDirection)
        self.vectorFieldStrength = component.vectorFieldStrength
        self.vectorFieldScale = component.vectorFieldScale
        self.vectorFieldScrollSpeed = component.vectorFieldScrollSpeed
        self.collisionMode = component.collisionMode
        self.simulationSpace = component.simulationSpace
        self.simulationBackend = component.simulationBackend
        self.gpuSimulationWorkgroupSize = component.gpuSimulationWorkgroupSize
        self.collisionPlaneY = component.collisionPlaneY
        self.collisionRestitution = component.collisionRestitution
        self.collisionDamping = component.collisionDamping
        self.startSize = component.startSize
        self.endSize = component.endSize
        self.sizeRandomness = component.sizeRandomness
        self.startRotation = component.startRotation
        self.rotationRandomness = component.rotationRandomness
        self.angularVelocity = component.angularVelocity
        self.angularVelocityRandomness = component.angularVelocityRandomness
        self.sizeCurve = component.sizeCurve
        self.startColor = EditorSceneManifestVector4(component.startColor)
        self.endColor = EditorSceneManifestVector4(component.endColor)
        self.colorCurve = component.colorCurve
        self.blendMode = component.blendMode
        self.renderMode = component.renderMode
        self.sortMode = component.sortMode
        self.renderSortPriority = component.renderSortPriority
        self.ribbonWidthScale = component.ribbonWidthScale
        self.ribbonTailWidthScale = component.ribbonTailWidthScale
        self.ribbonTailAlphaScale = component.ribbonTailAlphaScale
        self.ribbonMaxSegmentLength = component.ribbonMaxSegmentLength
        self.ribbonJoinOverlapScale = component.ribbonJoinOverlapScale
        self.ribbonSmoothingSegments = component.ribbonSmoothingSegments
        self.ribbonTextureTiling = component.ribbonTextureTiling
        self.ribbonTextureOffset = component.ribbonTextureOffset
        self.renderAlignment = component.renderAlignment
        self.velocityStretchScale = component.velocityStretchScale
        self.velocityStretchMax = component.velocityStretchMax
        self.maxRenderDistance = component.maxRenderDistance
        self.renderDistanceFadeRange = component.renderDistanceFadeRange
        self.renderLODStartDistance = component.renderLODStartDistance
        self.renderLODEndDistance = component.renderLODEndDistance
        self.renderLODMinParticleScale = component.renderLODMinParticleScale
        self.renderBoundsMode = component.renderBoundsMode
        self.renderBoundsRadius = component.renderBoundsRadius
        self.textureAssetID = component.textureAssetID
        self.texturePath = component.texturePath
        self.textureSheetColumns = component.textureSheetColumns
        self.textureSheetRows = component.textureSheetRows
        self.textureSheetFrameCount = component.textureSheetFrameCount
        self.textureSheetFrameRate = component.textureSheetFrameRate
        self.textureSheetPlaybackMode = component.textureSheetPlaybackMode
        self.textureSheetStartFrame = component.textureSheetStartFrame
        self.textureSheetFrameRandomness = component.textureSheetFrameRandomness
        self.trailLength = component.trailLength
        self.trailSegments = component.trailSegments
        self.trailEndSizeScale = component.trailEndSizeScale
        self.trailEndAlphaScale = component.trailEndAlphaScale
        self.seed = component.seed
        self.moduleStack = component.moduleStack
    }

    var component: ParticleEmitter {
        var emitter = ParticleEmitter(isEmitting: isEmitting, looping: looping, duration: duration,
                                      simulationSpeed: simulationSpeed,
                                      prewarmTime: prewarmTime,
                                      prewarmStep: prewarmStep,
                                      emissionRate: emissionRate,
                                      emissionRateCurve: emissionRateCurve,
                                      distanceEmissionRate: distanceEmissionRate,
                                      distanceEmissionRateCurve: distanceEmissionRateCurve,
                                      burstCount: burstCount, burstInterval: burstInterval,
                                      maxParticles: maxParticles,
                                      maxSpawnedParticlesPerFrame: maxSpawnedParticlesPerFrame,
                                      maxRenderedParticles: maxRenderedParticles,
                                      lifetime: lifetime,
                                      lifetimeRandomness: lifetimeRandomness,
                                      subEmitterTrigger: subEmitterTrigger,
                                      subEmitterBurstCount: subEmitterBurstCount,
                                      subEmitterProbability: subEmitterProbability,
                                      subEmitterMaxDepth: subEmitterMaxDepth,
                                      subEmitterInheritVelocity: subEmitterInheritVelocity,
                                      subEmitterLifetime: subEmitterLifetime,
                                      subEmitterStartVelocity: subEmitterStartVelocity.simdValue,
                                      subEmitterVelocityRandomness: subEmitterVelocityRandomness.simdValue,
                                      subEmitterStartSize: subEmitterStartSize,
                                      subEmitterEndSize: subEmitterEndSize,
                                      subEmitterStartColor: subEmitterStartColor.simdValue,
                                      subEmitterEndColor: subEmitterEndColor.simdValue,
                                      subEmitters: subEmitters.map(\.component),
                                      originOffset: originOffset.simdValue,
                                      spawnRadius: spawnRadius, emissionShape: emissionShape,
                                      boxHalfExtents: boxHalfExtents.simdValue,
                                      coneRadius: coneRadius, coneHeight: coneHeight,
                                      startVelocity: startVelocity.simdValue,
                                      velocityRandomness: velocityRandomness.simdValue,
                                      velocityInheritance: velocityInheritance,
                                      gravity: gravity.simdValue,
                                      noiseStrength: noiseStrength, noiseScale: noiseScale, noiseSpeed: noiseSpeed,
                                      forceMode: forceMode,
                                      forceCenter: forceCenter.simdValue,
                                      forceAxis: forceAxis.simdValue,
                                      forceRadius: forceRadius,
                                      forceStrength: forceStrength,
                                      forceFalloff: forceFalloff,
                                      vectorFieldMode: vectorFieldMode,
                                      vectorFieldDirection: vectorFieldDirection.simdValue,
                                      vectorFieldStrength: vectorFieldStrength,
                                      vectorFieldScale: vectorFieldScale,
                                      vectorFieldScrollSpeed: vectorFieldScrollSpeed,
                                      collisionMode: collisionMode, simulationSpace: simulationSpace,
                                      simulationBackend: simulationBackend,
                                      gpuSimulationWorkgroupSize: gpuSimulationWorkgroupSize,
                                      collisionPlaneY: collisionPlaneY,
                                      collisionRestitution: collisionRestitution, collisionDamping: collisionDamping,
                                      startSize: startSize, endSize: endSize, sizeRandomness: sizeRandomness,
                                      startRotation: startRotation, rotationRandomness: rotationRandomness,
                                      angularVelocity: angularVelocity, angularVelocityRandomness: angularVelocityRandomness,
                                      sizeCurve: sizeCurve,
                                      startColor: startColor.simdValue, endColor: endColor.simdValue,
                                      colorCurve: colorCurve, blendMode: blendMode,
                                      renderMode: renderMode,
                                      sortMode: sortMode,
                                      renderSortPriority: renderSortPriority,
                                      ribbonWidthScale: ribbonWidthScale,
                                      ribbonTailWidthScale: ribbonTailWidthScale,
                                      ribbonTailAlphaScale: ribbonTailAlphaScale,
                                      ribbonMaxSegmentLength: ribbonMaxSegmentLength,
                                      ribbonJoinOverlapScale: ribbonJoinOverlapScale,
                                      ribbonSmoothingSegments: ribbonSmoothingSegments,
                                      ribbonTextureTiling: ribbonTextureTiling,
                                      ribbonTextureOffset: ribbonTextureOffset,
                                      renderAlignment: renderAlignment,
                                      velocityStretchScale: velocityStretchScale,
                                      velocityStretchMax: velocityStretchMax,
                                      maxRenderDistance: maxRenderDistance,
                                      renderDistanceFadeRange: renderDistanceFadeRange,
                                      renderLODStartDistance: renderLODStartDistance,
                                      renderLODEndDistance: renderLODEndDistance,
                                      renderLODMinParticleScale: renderLODMinParticleScale,
                                      renderBoundsMode: renderBoundsMode,
                                      renderBoundsRadius: renderBoundsRadius,
                                      textureAssetID: textureAssetID, texturePath: texturePath,
                                      textureSheetColumns: textureSheetColumns,
                                      textureSheetRows: textureSheetRows,
                                      textureSheetFrameCount: textureSheetFrameCount,
                                      textureSheetFrameRate: textureSheetFrameRate,
                                      textureSheetPlaybackMode: textureSheetPlaybackMode,
                                      textureSheetStartFrame: textureSheetStartFrame,
                                      textureSheetFrameRandomness: textureSheetFrameRandomness,
                                      trailLength: trailLength,
                                      trailSegments: trailSegments,
                                      trailEndSizeScale: trailEndSizeScale,
                                      trailEndAlphaScale: trailEndAlphaScale,
                                      seed: seed)
        if let moduleStack {
            emitter.apply(moduleStack)
        }
        return emitter
    }

    private enum CodingKeys: String, CodingKey {
        case isEmitting, looping, duration, simulationSpeed, prewarmTime, prewarmStep, emissionRate, emissionRateCurve
        case distanceEmissionRate, distanceEmissionRateCurve, burstCount, burstInterval
        case maxParticles, maxSpawnedParticlesPerFrame, maxRenderedParticles, lifetime, lifetimeRandomness
        case subEmitterTrigger, subEmitterBurstCount, subEmitterProbability, subEmitterMaxDepth
        case subEmitterInheritVelocity, subEmitterLifetime
        case subEmitterStartVelocity, subEmitterVelocityRandomness
        case subEmitterStartSize, subEmitterEndSize, subEmitterStartColor, subEmitterEndColor
        case subEmitters
        case originOffset, spawnRadius, emissionShape, boxHalfExtents, coneRadius, coneHeight
        case startVelocity, velocityRandomness, velocityInheritance, gravity
        case noiseStrength, noiseScale, noiseSpeed
        case forceMode, forceCenter, forceAxis, forceRadius, forceStrength, forceFalloff
        case vectorFieldMode, vectorFieldDirection, vectorFieldStrength, vectorFieldScale, vectorFieldScrollSpeed
        case collisionMode, simulationSpace, simulationBackend, gpuSimulationWorkgroupSize
        case collisionPlaneY, collisionRestitution, collisionDamping
        case startSize, endSize, sizeRandomness
        case startRotation, rotationRandomness, angularVelocity, angularVelocityRandomness
        case sizeCurve, startColor, endColor, colorCurve, blendMode, renderMode, sortMode, renderSortPriority
        case ribbonWidthScale, ribbonTailWidthScale, ribbonTailAlphaScale, ribbonMaxSegmentLength
        case ribbonJoinOverlapScale, ribbonSmoothingSegments
        case ribbonTextureTiling, ribbonTextureOffset
        case renderAlignment, velocityStretchScale, velocityStretchMax
        case maxRenderDistance, renderDistanceFadeRange
        case renderLODStartDistance, renderLODEndDistance, renderLODMinParticleScale
        case renderBoundsMode, renderBoundsRadius
        case textureAssetID, texturePath
        case textureSheetColumns, textureSheetRows, textureSheetFrameCount, textureSheetFrameRate
        case textureSheetPlaybackMode, textureSheetStartFrame, textureSheetFrameRandomness
        case trailLength, trailSegments, trailEndSizeScale, trailEndAlphaScale, seed, moduleStack
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.isEmitting = try c.decodeIfPresent(Bool.self, forKey: .isEmitting) ?? true
        self.looping = try c.decodeIfPresent(Bool.self, forKey: .looping) ?? true
        self.duration = try c.decodeIfPresent(Float.self, forKey: .duration) ?? 0
        self.simulationSpeed = try c.decodeIfPresent(Float.self, forKey: .simulationSpeed) ?? 1
        self.prewarmTime = try c.decodeIfPresent(Float.self, forKey: .prewarmTime) ?? 0
        self.prewarmStep = try c.decodeIfPresent(Float.self, forKey: .prewarmStep) ?? (1.0 / 30.0)
        self.emissionRate = try c.decodeIfPresent(Float.self, forKey: .emissionRate) ?? 10
        self.emissionRateCurve = try c.decodeIfPresent(ParticleCurve.self, forKey: .emissionRateCurve) ?? .constant(1)
        self.distanceEmissionRate = try c.decodeIfPresent(Float.self, forKey: .distanceEmissionRate) ?? 0
        self.distanceEmissionRateCurve = try c.decodeIfPresent(ParticleCurve.self,
                                                                forKey: .distanceEmissionRateCurve) ?? .constant(1)
        self.burstCount = try c.decodeIfPresent(Int.self, forKey: .burstCount) ?? 0
        self.burstInterval = try c.decodeIfPresent(Float.self, forKey: .burstInterval) ?? 0
        self.maxParticles = try c.decodeIfPresent(Int.self, forKey: .maxParticles) ?? 256
        self.maxSpawnedParticlesPerFrame = try c.decodeIfPresent(Int.self,
                                                                  forKey: .maxSpawnedParticlesPerFrame) ?? 0
        self.maxRenderedParticles = try c.decodeIfPresent(Int.self, forKey: .maxRenderedParticles) ?? 0
        self.lifetime = try c.decodeIfPresent(Float.self, forKey: .lifetime) ?? 2
        self.lifetimeRandomness = try c.decodeIfPresent(Float.self, forKey: .lifetimeRandomness) ?? 0
        self.subEmitterTrigger = try c.decodeIfPresent(ParticleSubEmitterTrigger.self,
                                                        forKey: .subEmitterTrigger) ?? .none
        self.subEmitterBurstCount = try c.decodeIfPresent(Int.self, forKey: .subEmitterBurstCount) ?? 0
        self.subEmitterProbability = try c.decodeIfPresent(Float.self, forKey: .subEmitterProbability) ?? 1
        self.subEmitterMaxDepth = try c.decodeIfPresent(Int.self, forKey: .subEmitterMaxDepth) ?? 1
        self.subEmitterInheritVelocity = try c.decodeIfPresent(Float.self, forKey: .subEmitterInheritVelocity) ?? 0
        self.subEmitterLifetime = try c.decodeIfPresent(Float.self, forKey: .subEmitterLifetime) ?? 0.5
        self.subEmitterStartVelocity = try c.decodeIfPresent(EditorSceneManifestVector3.self,
                                                              forKey: .subEmitterStartVelocity)
            ?? EditorSceneManifestVector3(.zero)
        self.subEmitterVelocityRandomness = try c.decodeIfPresent(EditorSceneManifestVector3.self,
                                                                   forKey: .subEmitterVelocityRandomness)
            ?? EditorSceneManifestVector3(.zero)
        self.subEmitterStartSize = try c.decodeIfPresent(Float.self, forKey: .subEmitterStartSize) ?? 0.25
        self.subEmitterEndSize = try c.decodeIfPresent(Float.self, forKey: .subEmitterEndSize) ?? 0
        self.subEmitterStartColor = try c.decodeIfPresent(EditorSceneManifestVector4.self,
                                                           forKey: .subEmitterStartColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 1))
        self.subEmitterEndColor = try c.decodeIfPresent(EditorSceneManifestVector4.self,
                                                         forKey: .subEmitterEndColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 0))
        self.subEmitters = try c.decodeIfPresent([EditorSceneManifestParticleSubEmitter].self,
                                                  forKey: .subEmitters) ?? []
        self.originOffset = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .originOffset)
            ?? EditorSceneManifestVector3(.zero)
        self.spawnRadius = try c.decodeIfPresent(Float.self, forKey: .spawnRadius) ?? 0
        self.emissionShape = try c.decodeIfPresent(ParticleEmissionShape.self, forKey: .emissionShape) ?? .sphere
        self.boxHalfExtents = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .boxHalfExtents)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0.5, 0.5, 0.5))
        self.coneRadius = try c.decodeIfPresent(Float.self, forKey: .coneRadius) ?? 0.5
        self.coneHeight = try c.decodeIfPresent(Float.self, forKey: .coneHeight) ?? 1
        self.startVelocity = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .startVelocity)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, 1, 0))
        self.velocityRandomness = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .velocityRandomness)
            ?? EditorSceneManifestVector3(.zero)
        self.velocityInheritance = try c.decodeIfPresent(Float.self, forKey: .velocityInheritance) ?? 0
        self.gravity = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .gravity)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, -9.81, 0))
        self.noiseStrength = try c.decodeIfPresent(Float.self, forKey: .noiseStrength) ?? 0
        self.noiseScale = try c.decodeIfPresent(Float.self, forKey: .noiseScale) ?? 1
        self.noiseSpeed = try c.decodeIfPresent(Float.self, forKey: .noiseSpeed) ?? 1
        self.forceMode = try c.decodeIfPresent(ParticleForceMode.self, forKey: .forceMode) ?? .none
        self.forceCenter = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .forceCenter)
            ?? EditorSceneManifestVector3(.zero)
        self.forceAxis = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .forceAxis)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, 1, 0))
        self.forceRadius = try c.decodeIfPresent(Float.self, forKey: .forceRadius) ?? 0
        self.forceStrength = try c.decodeIfPresent(Float.self, forKey: .forceStrength) ?? 0
        self.forceFalloff = try c.decodeIfPresent(Float.self, forKey: .forceFalloff) ?? 1
        self.vectorFieldMode = try c.decodeIfPresent(ParticleVectorFieldMode.self, forKey: .vectorFieldMode) ?? .none
        self.vectorFieldDirection = try c.decodeIfPresent(EditorSceneManifestVector3.self,
                                                           forKey: .vectorFieldDirection)
            ?? EditorSceneManifestVector3(SIMD3<Float>(0, 1, 0))
        self.vectorFieldStrength = try c.decodeIfPresent(Float.self, forKey: .vectorFieldStrength) ?? 0
        self.vectorFieldScale = try c.decodeIfPresent(Float.self, forKey: .vectorFieldScale) ?? 1
        self.vectorFieldScrollSpeed = try c.decodeIfPresent(Float.self, forKey: .vectorFieldScrollSpeed) ?? 0
        self.collisionMode = try c.decodeIfPresent(ParticleCollisionMode.self, forKey: .collisionMode) ?? .none
        self.simulationSpace = try c.decodeIfPresent(ParticleSimulationSpace.self, forKey: .simulationSpace) ?? .local
        self.simulationBackend = try c.decodeIfPresent(ParticleSimulationBackend.self,
                                                        forKey: .simulationBackend) ?? .cpu
        self.gpuSimulationWorkgroupSize = try c.decodeIfPresent(Int.self, forKey: .gpuSimulationWorkgroupSize) ?? 64
        self.collisionPlaneY = try c.decodeIfPresent(Float.self, forKey: .collisionPlaneY) ?? 0
        self.collisionRestitution = try c.decodeIfPresent(Float.self, forKey: .collisionRestitution) ?? 0.5
        self.collisionDamping = try c.decodeIfPresent(Float.self, forKey: .collisionDamping) ?? 0
        self.startSize = try c.decodeIfPresent(Float.self, forKey: .startSize) ?? 1
        self.endSize = try c.decodeIfPresent(Float.self, forKey: .endSize) ?? 0
        self.sizeRandomness = try c.decodeIfPresent(Float.self, forKey: .sizeRandomness) ?? 0
        self.startRotation = try c.decodeIfPresent(Float.self, forKey: .startRotation) ?? 0
        self.rotationRandomness = try c.decodeIfPresent(Float.self, forKey: .rotationRandomness) ?? 0
        self.angularVelocity = try c.decodeIfPresent(Float.self, forKey: .angularVelocity) ?? 0
        self.angularVelocityRandomness = try c.decodeIfPresent(Float.self, forKey: .angularVelocityRandomness) ?? 0
        self.sizeCurve = try c.decodeIfPresent(ParticleCurve.self, forKey: .sizeCurve) ?? .linear
        self.startColor = try c.decodeIfPresent(EditorSceneManifestVector4.self, forKey: .startColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 1))
        self.endColor = try c.decodeIfPresent(EditorSceneManifestVector4.self, forKey: .endColor)
            ?? EditorSceneManifestVector4(SIMD4<Float>(1, 1, 1, 0))
        self.colorCurve = try c.decodeIfPresent(ParticleCurve.self, forKey: .colorCurve) ?? .linear
        self.blendMode = try c.decodeIfPresent(ParticleBlendMode.self, forKey: .blendMode) ?? .alpha
        self.renderMode = try c.decodeIfPresent(ParticleRenderMode.self, forKey: .renderMode) ?? .billboard
        self.sortMode = try c.decodeIfPresent(ParticleSortMode.self, forKey: .sortMode) ?? .distanceDescending
        self.renderSortPriority = try c.decodeIfPresent(Int.self, forKey: .renderSortPriority) ?? 0
        self.ribbonWidthScale = try c.decodeIfPresent(Float.self, forKey: .ribbonWidthScale) ?? 1
        self.ribbonTailWidthScale = try c.decodeIfPresent(Float.self, forKey: .ribbonTailWidthScale) ?? 1
        self.ribbonTailAlphaScale = try c.decodeIfPresent(Float.self, forKey: .ribbonTailAlphaScale) ?? 1
        self.ribbonMaxSegmentLength = try c.decodeIfPresent(Float.self, forKey: .ribbonMaxSegmentLength) ?? 0
        self.ribbonJoinOverlapScale = try c.decodeIfPresent(Float.self, forKey: .ribbonJoinOverlapScale) ?? 0
        self.ribbonSmoothingSegments = try c.decodeIfPresent(Int.self, forKey: .ribbonSmoothingSegments) ?? 1
        self.ribbonTextureTiling = try c.decodeIfPresent(Float.self, forKey: .ribbonTextureTiling) ?? 0
        self.ribbonTextureOffset = try c.decodeIfPresent(Float.self, forKey: .ribbonTextureOffset) ?? 0
        self.renderAlignment = try c.decodeIfPresent(ParticleRenderAlignment.self,
                                                      forKey: .renderAlignment) ?? .billboard
        self.velocityStretchScale = try c.decodeIfPresent(Float.self, forKey: .velocityStretchScale) ?? 0
        self.velocityStretchMax = try c.decodeIfPresent(Float.self, forKey: .velocityStretchMax) ?? 8
        self.maxRenderDistance = try c.decodeIfPresent(Float.self, forKey: .maxRenderDistance) ?? 0
        self.renderDistanceFadeRange = try c.decodeIfPresent(Float.self, forKey: .renderDistanceFadeRange) ?? 0
        self.renderLODStartDistance = try c.decodeIfPresent(Float.self, forKey: .renderLODStartDistance) ?? 0
        self.renderLODEndDistance = try c.decodeIfPresent(Float.self, forKey: .renderLODEndDistance) ?? 0
        self.renderLODMinParticleScale = try c.decodeIfPresent(Float.self, forKey: .renderLODMinParticleScale) ?? 1
        self.renderBoundsRadius = try c.decodeIfPresent(Float.self, forKey: .renderBoundsRadius) ?? 0
        self.renderBoundsMode = try c.decodeIfPresent(ParticleRenderBoundsMode.self, forKey: .renderBoundsMode)
            ?? (renderBoundsRadius > 0 ? .manual : .disabled)
        self.textureAssetID = try c.decodeIfPresent(String.self, forKey: .textureAssetID)
        self.texturePath = try c.decodeIfPresent(String.self, forKey: .texturePath)
        self.textureSheetColumns = try c.decodeIfPresent(Int.self, forKey: .textureSheetColumns) ?? 1
        self.textureSheetRows = try c.decodeIfPresent(Int.self, forKey: .textureSheetRows) ?? 1
        self.textureSheetFrameCount = try c.decodeIfPresent(Int.self, forKey: .textureSheetFrameCount) ?? 1
        self.textureSheetFrameRate = try c.decodeIfPresent(Float.self, forKey: .textureSheetFrameRate) ?? 0
        self.textureSheetPlaybackMode = try c.decodeIfPresent(ParticleTextureSheetPlaybackMode.self,
                                                               forKey: .textureSheetPlaybackMode) ?? .automatic
        self.textureSheetStartFrame = try c.decodeIfPresent(Int.self, forKey: .textureSheetStartFrame) ?? 0
        self.textureSheetFrameRandomness = try c.decodeIfPresent(Int.self,
                                                                  forKey: .textureSheetFrameRandomness) ?? 0
        self.trailLength = try c.decodeIfPresent(Float.self, forKey: .trailLength) ?? 0
        self.trailSegments = try c.decodeIfPresent(Int.self, forKey: .trailSegments) ?? 0
        self.trailEndSizeScale = try c.decodeIfPresent(Float.self, forKey: .trailEndSizeScale) ?? 0.5
        self.trailEndAlphaScale = try c.decodeIfPresent(Float.self, forKey: .trailEndAlphaScale) ?? 0
        self.seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0x9E3779B9
        self.moduleStack = try c.decodeIfPresent(ParticleModuleStack.self, forKey: .moduleStack)
    }
}
