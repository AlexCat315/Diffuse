import Foundation
import SIMDCompat

/// Renderer-facing scene description extracted from `SceneRuntime`.
/// `RenderScene` is the complete data contract handed from SceneRuntime to
/// RenderBackend: camera, draw instances, lights, material overrides, and the
/// scene environment for one frame.
public struct RenderMeshHandle: Sendable, Equatable {
    public var meshIndex: Int
    public var assetID: String?

    public init(meshIndex: Int, assetID: String? = nil) {
        self.meshIndex = meshIndex
        self.assetID = assetID
    }
}

public struct RenderMaterial: Sendable, Equatable {
    public var baseColorFactor: SIMD4<Float>
    public var baseColorTextureIndex: Int?
    public var normalTextureIndex: Int?
    public var metallicFactor: Float
    public var roughnessFactor: Float
    public var emissiveFactor: SIMD3<Float>

    public init(baseColorFactor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                baseColorTextureIndex: Int? = nil,
                normalTextureIndex: Int? = nil,
                metallicFactor: Float = 0,
                roughnessFactor: Float = 1,
                emissiveFactor: SIMD3<Float> = .zero) {
        self.baseColorFactor = baseColorFactor
        self.baseColorTextureIndex = baseColorTextureIndex
        self.normalTextureIndex = normalTextureIndex
        self.metallicFactor = max(0, min(1, metallicFactor))
        self.roughnessFactor = max(0, min(1, roughnessFactor))
        self.emissiveFactor = emissiveFactor
    }

    public static let fallback = RenderMaterial()
}

public enum RenderLightType: String, Sendable, Equatable {
    case directional
    case point
    case spot
}

public struct RenderLight: Sendable, Equatable {
    public var type: RenderLightType
    public var position: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var color: SIMD3<Float>
    public var intensity: Float
    public var range: Float
    public var spotInnerAngleRadians: Float
    public var spotOuterAngleRadians: Float
    public var castShadows: Bool
    public var entity: EntityID?

    public init(type: RenderLightType = .directional,
                position: SIMD3<Float> = .zero,
                direction: SIMD3<Float> = SIMD3<Float>(0, -1, 0),
                color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                intensity: Float = 1,
                range: Float = 10,
                spotInnerAngleRadians: Float = .pi / 9,
                spotOuterAngleRadians: Float = .pi / 6,
                castShadows: Bool = false,
                entity: EntityID? = nil) {
        self.type = type
        self.position = position
        self.direction = direction
        self.color = color
        self.intensity = max(0, intensity)
        self.range = max(0, range)
        self.spotOuterAngleRadians = max(0.001, min(.pi, spotOuterAngleRadians))
        self.spotInnerAngleRadians = max(0, min(self.spotOuterAngleRadians, spotInnerAngleRadians))
        self.castShadows = castShadows
        self.entity = entity
    }
}

public struct RenderEnvironment: Sendable, Equatable {
    public var ambientColor: SIMD3<Float>
    public var ambientIntensity: Float
    public var exposure: Float

    public init(ambientColor: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                ambientIntensity: Float = 0.03,
                exposure: Float = 1) {
        self.ambientColor = ambientColor
        self.ambientIntensity = max(0, ambientIntensity)
        self.exposure = max(0, exposure)
    }

    public static let fallback = RenderEnvironment()
}

/// One `RenderInstance` = one draw call. `meshIndex` references a mesh
/// previously registered with the renderer's mesh table.
public struct RenderInstance: Sendable {
    public var entity: EntityID?
    public var mesh: RenderMeshHandle
    public var transform: simd_float4x4
    public var colorTint: SIMD3<Float>
    public var material: RenderMaterial

    public var meshIndex: Int {
        get { mesh.meshIndex }
        set { mesh.meshIndex = newValue }
    }

    public init(mesh: RenderMeshHandle,
                transform: simd_float4x4,
                colorTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                material: RenderMaterial = .fallback,
                entity: EntityID? = nil) {
        self.entity = entity
        self.mesh = mesh
        self.transform = transform
        self.colorTint = colorTint
        self.material = material
    }

    public init(meshIndex: Int,
                transform: simd_float4x4,
                colorTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                material: RenderMaterial = .fallback,
                entity: EntityID? = nil) {
        self.init(mesh: RenderMeshHandle(meshIndex: meshIndex),
                  transform: transform,
                  colorTint: colorTint,
                  material: material,
                  entity: entity)
    }
}

public enum RenderParticleShape: UInt32, Sendable, Equatable {
    case softBillboard = 0
    case ribbonSegment = 1
}

/// One camera-facing billboard particle, already transformed to world space and
/// ready for the render backend. Built each frame from live `ParticleEmitter`
/// pools; the renderer uploads these into a storage buffer and draws them as
/// instanced quads.
public struct RenderParticle: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var size: Float
    public var rotation: Float
    public var color: SIMD4<Float>
    /// Ribbon end color. Billboard particles keep this equal to `color`.
    public var endColor: SIMD4<Float>
    /// Texture sheet UV rect: x, y, width, height.
    public var uvRect: SIMD4<Float>
    /// Optional world-space axis used for velocity-aligned billboard rendering.
    public var alignmentAxis: SIMD3<Float>
    /// Multiplier applied along `alignmentAxis`; 1 keeps the particle square.
    public var stretch: Float
    /// Ribbon start width. Billboard particles keep this equal to `size`.
    public var startSize: Float
    /// Ribbon end width. Billboard particles keep this equal to `size`.
    public var endSize: Float
    /// Fragment alpha model used by the particle shader.
    public var shape: RenderParticleShape
    /// Ribbon-only V coordinate offset. Used when `textureVScale` is greater than zero.
    public var textureVOffset: Float
    /// Ribbon-only V coordinate scale. Zero keeps the particle's authored UV rect unchanged.
    public var textureVScale: Float
    public var blendMode: ParticleBlendMode
    public var texturePath: String?

    public init(position: SIMD3<Float>,
                size: Float,
                rotation: Float = 0,
                color: SIMD4<Float>,
                endColor: SIMD4<Float>? = nil,
                uvRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
                alignmentAxis: SIMD3<Float> = .zero,
                stretch: Float = 1,
                startSize: Float? = nil,
                endSize: Float? = nil,
                shape: RenderParticleShape = .softBillboard,
                textureVOffset: Float = 0,
                textureVScale: Float = 0,
                blendMode: ParticleBlendMode = .alpha,
                texturePath: String? = nil) {
        self.position = position
        self.size = size
        self.rotation = rotation
        self.color = color
        self.endColor = endColor ?? color
        self.uvRect = uvRect
        self.alignmentAxis = alignmentAxis
        self.stretch = max(1, stretch)
        self.startSize = max(0, startSize ?? size)
        self.endSize = max(0, endSize ?? size)
        self.shape = shape
        self.textureVOffset = textureVOffset
        self.textureVScale = max(0, textureVScale)
        self.blendMode = blendMode
        self.texturePath = texturePath
    }
}

public struct RenderBounds: Sendable, Equatable {
    public var isEmpty: Bool
    public var minimum: SIMD3<Float>
    public var maximum: SIMD3<Float>

    public init(isEmpty: Bool = true,
                minimum: SIMD3<Float> = .zero,
                maximum: SIMD3<Float> = .zero) {
        self.isEmpty = isEmpty
        self.minimum = minimum
        self.maximum = maximum
    }

    public mutating func include(center: SIMD3<Float>, radius: Float) {
        let r = max(0, radius)
        let minimum = center - SIMD3<Float>(repeating: r)
        let maximum = center + SIMD3<Float>(repeating: r)
        if isEmpty {
            self.minimum = minimum
            self.maximum = maximum
            isEmpty = false
        } else {
            self.minimum = simd_min(self.minimum, minimum)
            self.maximum = simd_max(self.maximum, maximum)
        }
    }
}

public struct ParticleRenderBatchKey: Hashable, Sendable, Equatable {
    public var blendMode: ParticleBlendMode
    public var texturePath: String?

    public init(blendMode: ParticleBlendMode, texturePath: String? = nil) {
        self.blendMode = blendMode
        self.texturePath = normalizedParticleTexturePath(texturePath)
    }

    public init(particle: RenderParticle) {
        self.init(blendMode: particle.blendMode, texturePath: particle.texturePath)
    }
}

public struct ParticleRenderBatch: Sendable, Equatable {
    public var key: ParticleRenderBatchKey
    public var start: Int
    public var count: Int

    public init(key: ParticleRenderBatchKey, start: Int, count: Int) {
        self.key = key
        self.start = max(0, start)
        self.count = max(0, count)
    }
}

public struct ParticleRenderBatchPlan: Sendable, Equatable {
    public var batches: [ParticleRenderBatch]
    public var uniqueTextureCount: Int

    public init(particles: [RenderParticle]) {
        var batches: [ParticleRenderBatch] = []
        batches.reserveCapacity(max(1, particles.count))
        var uniqueTextures = Set<String>()
        var currentKey: ParticleRenderBatchKey?
        var currentStart = 0

        for (index, particle) in particles.enumerated() {
            let key = ParticleRenderBatchKey(particle: particle)
            if let texturePath = key.texturePath {
                uniqueTextures.insert(texturePath)
            }
            if let currentKey, currentKey != key {
                batches.append(ParticleRenderBatch(key: currentKey,
                                                   start: currentStart,
                                                   count: index - currentStart))
                currentStart = index
            }
            currentKey = key
        }

        if let currentKey {
            batches.append(ParticleRenderBatch(key: currentKey,
                                               start: currentStart,
                                               count: particles.count - currentStart))
        }

        self.batches = batches
        self.uniqueTextureCount = uniqueTextures.count
    }
}

public struct ParticleRenderSummary: Sendable, Equatable {
    public var particleCount: Int
    public var alphaCount: Int
    public var additiveCount: Int
    public var texturedCount: Int
    public var uniqueTextureCount: Int
    public var batchCount: Int
    public var bounds: RenderBounds

    public init(particleCount: Int = 0,
                alphaCount: Int = 0,
                additiveCount: Int = 0,
                texturedCount: Int = 0,
                uniqueTextureCount: Int = 0,
                batchCount: Int = 0,
                bounds: RenderBounds = RenderBounds()) {
        self.particleCount = max(0, particleCount)
        self.alphaCount = max(0, alphaCount)
        self.additiveCount = max(0, additiveCount)
        self.texturedCount = max(0, texturedCount)
        self.uniqueTextureCount = max(0, uniqueTextureCount)
        self.batchCount = max(0, batchCount)
        self.bounds = bounds
    }

    public init(particles: [RenderParticle]) {
        var alphaCount = 0
        var additiveCount = 0
        var texturedCount = 0
        var bounds = RenderBounds()
        let batchPlan = ParticleRenderBatchPlan(particles: particles)

        for particle in particles {
            switch particle.blendMode {
            case .alpha:
                alphaCount += 1
            case .additive:
                additiveCount += 1
            }
            if normalizedParticleTexturePath(particle.texturePath) != nil {
                texturedCount += 1
            }
            bounds.include(center: particle.position,
                           radius: particle.conservativeRadius)
        }

        self.init(particleCount: particles.count,
                  alphaCount: alphaCount,
                  additiveCount: additiveCount,
                  texturedCount: texturedCount,
                  uniqueTextureCount: batchPlan.uniqueTextureCount,
                  batchCount: batchPlan.batches.count,
                  bounds: bounds)
    }
}

public struct RenderParticleSimulationBatch: Sendable, Equatable {
    /// Stable source emitter identity. RenderBackend uses this to keep GPU state
    /// resources attached to an emitter when batch order changes.
    public var emitterEntity: EntityID?
    public var plan: ParticleGPUSimulationPlan
    /// Persisted particles already resident in the simulation state at frame start.
    public var particles: [Particle]
    /// Newly spawned particles appended by the GPU before this frame's simulation pass.
    public var spawnParticles: [Particle]
    public var gravity: SIMD3<Float>
    public var noiseStrength: Float
    public var noiseScale: Float
    public var noiseSpeed: Float
    public var noiseSeed: UInt64
    public var vectorFieldMode: ParticleVectorFieldMode
    public var vectorFieldDirection: SIMD3<Float>
    public var vectorFieldStrength: Float
    public var vectorFieldScale: Float
    public var vectorFieldScrollSpeed: Float
    public var forceMode: ParticleForceMode
    public var forceCenter: SIMD3<Float>
    public var forceAxis: SIMD3<Float>
    public var forceRadius: Float
    public var forceStrength: Float
    public var forceFalloff: Float
    public var collisionMode: ParticleCollisionMode
    public var collisionPlaneY: Float
    public var collisionRestitution: Float
    public var collisionDamping: Float
    public var renderOnGPU: Bool
    public var worldTransform: simd_float4x4
    public var uvRect: SIMD4<Float>
    public var textureSheetColumns: Int
    public var textureSheetRows: Int
    public var textureSheetFrameCount: Int
    public var textureSheetFrameRate: Float
    public var textureSheetPlaybackMode: ParticleTextureSheetPlaybackMode
    public var textureSheetStartFrame: Int
    public var textureSheetFrameRandomness: Int
    public var blendMode: ParticleBlendMode
    public var texturePath: String?
    public var renderAlignment: ParticleRenderAlignment
    public var velocityStretchScale: Float
    public var velocityStretchMax: Float
    public var sortMode: ParticleSortMode
    /// Effective number of simulated particles to submit for rendering. A zero
    /// value keeps every live simulated particle visible.
    public var renderParticleLimit: Int
    public var renderAlphaScale: Float
    public var trailLength: Float
    public var trailSegments: Int
    public var trailEndSizeScale: Float
    public var trailEndAlphaScale: Float

    public init(emitterEntity: EntityID? = nil,
                plan: ParticleGPUSimulationPlan,
                particles: [Particle],
                spawnParticles: [Particle] = [],
                gravity: SIMD3<Float>,
                noiseStrength: Float = 0,
                noiseScale: Float = 1,
                noiseSpeed: Float = 0,
                noiseSeed: UInt64 = 0,
                vectorFieldMode: ParticleVectorFieldMode = .none,
                vectorFieldDirection: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                vectorFieldStrength: Float = 0,
                vectorFieldScale: Float = 1,
                vectorFieldScrollSpeed: Float = 0,
                forceMode: ParticleForceMode = .none,
                forceCenter: SIMD3<Float> = .zero,
                forceAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                forceRadius: Float = 0,
                forceStrength: Float = 0,
                forceFalloff: Float = 1,
                collisionMode: ParticleCollisionMode = .none,
                collisionPlaneY: Float = 0,
                collisionRestitution: Float = 0.5,
                collisionDamping: Float = 0,
                renderOnGPU: Bool = false,
                worldTransform: simd_float4x4 = matrix_identity_float4x4,
                uvRect: SIMD4<Float> = SIMD4<Float>(0, 0, 1, 1),
                textureSheetColumns: Int = 1,
                textureSheetRows: Int = 1,
                textureSheetFrameCount: Int = 1,
                textureSheetFrameRate: Float = 0,
                textureSheetPlaybackMode: ParticleTextureSheetPlaybackMode = .automatic,
                textureSheetStartFrame: Int = 0,
                textureSheetFrameRandomness: Int = 0,
                blendMode: ParticleBlendMode = .alpha,
                texturePath: String? = nil,
                renderAlignment: ParticleRenderAlignment = .billboard,
                velocityStretchScale: Float = 0,
                velocityStretchMax: Float = 8,
                sortMode: ParticleSortMode = .distanceDescending,
                renderParticleLimit: Int = 0,
                renderAlphaScale: Float = 1,
                trailLength: Float = 0,
                trailSegments: Int = 0,
                trailEndSizeScale: Float = 0.5,
                trailEndAlphaScale: Float = 0) {
        self.emitterEntity = emitterEntity
        self.plan = plan
        self.particles = particles
        self.spawnParticles = spawnParticles
        self.gravity = gravity
        self.noiseStrength = max(0, noiseStrength)
        self.noiseScale = max(0.0001, noiseScale)
        self.noiseSpeed = max(0, noiseSpeed)
        self.noiseSeed = noiseSeed
        self.vectorFieldMode = vectorFieldMode
        self.vectorFieldDirection = vectorFieldDirection
        self.vectorFieldStrength = max(0, vectorFieldStrength)
        self.vectorFieldScale = max(0.0001, vectorFieldScale)
        self.vectorFieldScrollSpeed = vectorFieldScrollSpeed
        self.forceMode = forceMode
        self.forceCenter = forceCenter
        self.forceAxis = forceAxis
        self.forceRadius = max(0, forceRadius)
        self.forceStrength = forceStrength
        self.forceFalloff = max(0, forceFalloff)
        self.collisionMode = collisionMode
        self.collisionPlaneY = collisionPlaneY
        self.collisionRestitution = simd_clamp(collisionRestitution, 0, 1)
        self.collisionDamping = simd_clamp(collisionDamping, 0, 1)
        self.renderOnGPU = renderOnGPU
        self.worldTransform = worldTransform
        self.uvRect = uvRect
        self.textureSheetColumns = max(1, textureSheetColumns)
        self.textureSheetRows = max(1, textureSheetRows)
        self.textureSheetFrameCount = max(1, textureSheetFrameCount)
        self.textureSheetFrameRate = max(0, textureSheetFrameRate)
        self.textureSheetPlaybackMode = textureSheetPlaybackMode
        self.textureSheetStartFrame = max(0, textureSheetStartFrame)
        self.textureSheetFrameRandomness = max(0, textureSheetFrameRandomness)
        self.blendMode = blendMode
        self.texturePath = normalizedParticleTexturePath(texturePath)
        self.renderAlignment = renderAlignment
        self.velocityStretchScale = max(0, velocityStretchScale)
        self.velocityStretchMax = max(1, velocityStretchMax)
        self.sortMode = sortMode
        self.renderParticleLimit = max(0, renderParticleLimit)
        self.renderAlphaScale = simd_clamp(renderAlphaScale, 0, 1)
        self.trailLength = max(0, trailLength)
        self.trailSegments = max(0, trailSegments)
        self.trailEndSizeScale = max(0, trailEndSizeScale)
        self.trailEndAlphaScale = simd_clamp(trailEndAlphaScale, 0, 1)
    }

    public var particleCount: Int {
        let capacity = max(0, plan.particleCapacity)
        let baseCount = min(particles.count, capacity)
        let spawnCount = min(spawnParticles.count, max(0, capacity - baseCount))
        return baseCount + spawnCount
    }

    public var renderInstanceMultiplier: Int {
        1 + (trailLength > 0 ? max(0, trailSegments) : 0)
    }

    public var renderParticleCount: Int {
        let count = particleCount
        guard renderParticleLimit > 0 else { return count }
        return min(renderParticleLimit, count)
    }

    public var renderParticleStartIndex: Int {
        max(0, particleCount - renderParticleCount)
    }

    public var renderInstanceCount: Int {
        renderParticleCount * renderInstanceMultiplier
    }
}

private func normalizedParticleTexturePath(_ path: String?) -> String? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty
    else { return nil }
    return path
}

private extension RenderParticle {
    var conservativeRadius: Float {
        max(0, size) * max(1, stretch) * 0.70710678
    }
}

public struct RenderCamera: Sendable, Equatable {
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var fovYRadians: Float
    public var aspectRatio: Float
    public var near: Float
    public var far: Float

    public init(eye: SIMD3<Float>,
                target: SIMD3<Float> = .zero,
                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                fovYRadians: Float = .pi / 4,
                aspectRatio: Float = 1,
                near: Float = 0.1,
                far: Float = 100.0) {
        self.eye = eye
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.aspectRatio = max(0.001, aspectRatio)
        self.near = near
        self.far = far
    }
}

public struct RenderScene: Sendable {
    public var camera: RenderCamera
    public var instances: [RenderInstance]
    public var lights: [RenderLight]
    public var environment: RenderEnvironment
    /// World-space billboard particles, pre-sorted back-to-front for the camera.
    public var particles: [RenderParticle]
    /// GPU-simulation input batches extracted from authored particle emitters.
    public var particleSimulationBatches: [RenderParticleSimulationBatch]
    /// Aggregate particle bounds and batch-count hints for culling, budgets, and profiler UI.
    public var particleSummary: ParticleRenderSummary

    public init(camera: RenderCamera,
                instances: [RenderInstance] = [],
                lights: [RenderLight] = [],
                environment: RenderEnvironment = .fallback,
                particles: [RenderParticle] = [],
                particleSimulationBatches: [RenderParticleSimulationBatch] = [],
                particleSummary: ParticleRenderSummary? = nil) {
        self.camera = camera
        self.instances = instances
        self.lights = lights
        self.environment = environment
        self.particles = particles
        self.particleSimulationBatches = particleSimulationBatches
        self.particleSummary = particleSummary ?? ParticleRenderSummary(particles: particles)
    }
}
