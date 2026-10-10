import EngineKernel
import SIMDCompat

extension RuntimeWorldSchedule {
    func particleAdvanceOptions(in world: inout RuntimeWorld) -> ParticleAdvanceOptions {
        let baseOptions = (world.resource(ParticleScalabilityResource.self)
            ?? .default).advanceOptions
        let policy = world.resource(ParticleScalabilityPolicyResource.self) ?? .disabled
        let state = policy.updatedState(
            previousStats: world.resource(ParticleFrameStatsResource.self) ?? .empty,
            previousState: world.resource(ParticleScalabilityStateResource.self) ?? .default
        )
        world.setDerivedResource(state)
        return state.applying(to: baseOptions)
    }


    func collectParticleSimulationBatches(in world: RuntimeWorld,
                                                  camera: RenderCamera)
        -> [RenderParticleSimulationBatch] {
        var result: [RenderParticleSimulationBatch] = []
        for entity in world.entities(with: ParticleEmitter.self) {
            guard let emitter = world.component(ParticleEmitter.self, for: entity),
                  !emitter.particles.isEmpty
            else { continue }
            let plan = emitter.gpuSimulationPlan
            guard plan.usesGPU else { continue }
            let toWorld = world.worldTransform(for: entity)?.matrix ?? matrix_identity_float4x4
            let canRenderOnGPU = canRenderEmitterParticlesOnGPU(emitter)
            let isRenderVisible = canRenderOnGPU
                && isEmitterVisibleToCamera(emitter: emitter,
                                            toWorld: toWorld,
                                            camera: camera)
            let distanceFade = isRenderVisible
                ? renderDistanceFade(emitter: emitter, toWorld: toWorld, cameraEye: camera.eye)
                : 0
            let cameraDistance = emitterCameraDistance(emitter: emitter,
                                                       toWorld: toWorld,
                                                       cameraEye: camera.eye)
            let renderParticleLimit = emitter.effectiveMaxRenderedParticles(
                cameraDistance: cameraDistance,
                liveParticleCount: emitter.particles.count
            )
            let renderOnGPU = canRenderOnGPU && distanceFade > 0 && renderParticleLimit > 0
            let renderAlphaScale = renderOnGPU ? distanceFade : 0
            let frameSpawnCount = min(
                emitter.lastFrameSpawnedParticles.count,
                emitter.lastFrameStats.spawnedParticleCount,
                emitter.particles.count
            )
            let persistedParticleCount = max(0, emitter.particles.count - frameSpawnCount)
            let persistedParticles = Array(emitter.particles.prefix(persistedParticleCount))
            let spawnParticles = Array(emitter.lastFrameSpawnedParticles.suffix(frameSpawnCount))
            result.append(
                RenderParticleSimulationBatch(
                    emitterEntity: entity,
                    plan: plan,
                    particles: persistedParticles,
                    spawnParticles: spawnParticles,
                    simulationSpeed: emitter.settings.emission.simulationSpeed,
                    gravity: emitter.settings.forces.gravity,
                    noiseStrength: emitter.settings.forces.noiseStrength,
                    noiseScale: emitter.settings.forces.noiseScale,
                    noiseSpeed: emitter.settings.forces.noiseSpeed,
                    noiseSeed: emitter.settings.emission.seed,
                    vectorFieldMode: emitter.settings.forces.vectorFieldMode,
                    vectorFieldDirection: emitter.settings.forces.vectorFieldDirection,
                    vectorFieldStrength: emitter.settings.forces.vectorFieldStrength,
                    vectorFieldScale: emitter.settings.forces.vectorFieldScale,
                    vectorFieldScrollSpeed: emitter.settings.forces.vectorFieldScrollSpeed,
                    forceMode: emitter.settings.forces.forceMode,
                    forceCenter: emitter.settings.forces.forceCenter,
                    forceAxis: emitter.settings.forces.forceAxis,
                    forceRadius: emitter.settings.forces.forceRadius,
                    forceStrength: emitter.settings.forces.forceStrength,
                    forceFalloff: emitter.settings.forces.forceFalloff,
                    collisionMode: emitter.settings.collision.collisionMode,
                    collisionPlaneY: emitter.settings.collision.collisionPlaneY,
                    collisionRestitution: emitter.settings.collision.collisionRestitution,
                    collisionDamping: emitter.settings.collision.collisionDamping,
                    renderOnGPU: renderOnGPU,
                    worldTransform: emitter.settings.gpuSimulation.simulationSpace == .local ? toWorld : matrix_identity_float4x4,
                    uvRect: SIMD4<Float>(0, 0, 1, 1),
                    textureSheetColumns: emitter.settings.textureSheet.columns,
                    textureSheetRows: emitter.settings.textureSheet.rows,
                    textureSheetFrameCount: emitter.settings.textureSheet.frameCount,
                    textureSheetFrameRate: emitter.settings.textureSheet.frameRate,
                    textureSheetPlaybackMode: emitter.settings.textureSheet.playbackMode,
                    textureSheetStartFrame: emitter.settings.textureSheet.startFrame,
                    textureSheetFrameRandomness: emitter.settings.textureSheet.frameRandomness,
                    startSize: emitter.settings.appearance.startSize,
                    endSize: emitter.settings.appearance.endSize,
                    sizeCurve: emitter.settings.appearance.sizeCurve,
                    startColor: emitter.settings.appearance.startColor,
                    endColor: emitter.settings.appearance.endColor,
                    colorCurve: emitter.settings.appearance.colorCurve,
                    usesAuthoredAppearance: true,
                    appearancePalette: renderParticleAppearancePalette(for: emitter),
                    blendMode: emitter.settings.appearance.blendMode,
                    texturePath: emitter.settings.textureSheet.texturePath,
                    renderAlignment: emitter.settings.renderer.renderAlignment,
                    velocityStretchScale: emitter.settings.renderer.velocityStretchScale,
                    velocityStretchMax: emitter.settings.renderer.velocityStretchMax,
                    sortMode: emitter.settings.renderer.sortMode,
                    renderSortPriority: emitter.settings.renderer.renderSortPriority,
                    renderParticleLimit: renderParticleLimit,
                    renderAlphaScale: renderAlphaScale,
                    trailLength: emitter.settings.trails.trailLength,
                    trailSegments: emitter.settings.trails.trailSegments,
                    trailEndSizeScale: emitter.settings.trails.trailEndSizeScale,
                    trailEndAlphaScale: emitter.settings.trails.trailEndAlphaScale
                )
            )
        }
        result.sort { lhs, rhs in
            if lhs.renderSortPriority != rhs.renderSortPriority {
                return lhs.renderSortPriority < rhs.renderSortPriority
            }
            return (lhs.emitterEntity?.rawValue ?? 0) < (rhs.emitterEntity?.rawValue ?? 0)
        }
        return result
    }

    func renderParticleAppearancePalette(for emitter: ParticleEmitter) -> [RenderParticleAppearance] {
        var palette = [
            RenderParticleAppearance(startSize: emitter.settings.appearance.startSize,
                                     endSize: emitter.settings.appearance.endSize,
                                     startColor: emitter.settings.appearance.startColor,
                                     endColor: emitter.settings.appearance.endColor),
            RenderParticleAppearance(startSize: emitter.settings.subEmitters.legacyStartSize,
                                     endSize: emitter.settings.subEmitters.legacyEndSize,
                                     startColor: emitter.settings.subEmitters.legacyStartColor,
                                     endColor: emitter.settings.subEmitters.legacyEndColor),
        ]
        palette.append(contentsOf: emitter.settings.subEmitters.rules.map {
            RenderParticleAppearance(startSize: $0.startSize,
                                     endSize: $0.endSize,
                                     startColor: $0.startColor,
                                     endColor: $0.endColor)
        })
        return palette
    }

    func canRenderEmitterParticlesOnGPU(_ emitter: ParticleEmitter) -> Bool {
        guard emitter.gpuSimulationPlan.usesGPU else { return false }
        guard emitter.settings.renderer.renderMode == .billboard else { return false }
        guard emitter.settings.renderer.renderAlignment == .billboard || emitter.settings.renderer.renderAlignment == .velocity else { return false }
        guard emitter.settings.textureSheet.textureAssetID == nil || emitter.settings.textureSheet.texturePath != nil else { return false }
        return true
    }

    /// Flattens every live `ParticleEmitter` pool into world-space billboard
    /// particles for the render backend. Local-space particles are transformed
    /// by the entity's world matrix; world-space particles are already stored in
    /// render space. The result is sorted back-to-front for the camera so alpha
    /// blending composites correctly.
    struct CollectedRenderParticles {
        var particles: [RenderParticle]
        var sourceParticleCount: Int
        var submittedSourceParticleCount: Int
    }

    func collectRenderParticles(
        in world: RuntimeWorld,
        camera: RenderCamera
    ) -> CollectedRenderParticles {
        var sortableParticles: [SortableRenderParticle] = []
        var nextSourceOrder = 0
        var sourceParticleCount = 0
        var submittedSourceParticleCount = 0
        for entity in world.entities(with: ParticleEmitter.self) {
            guard let emitter = world.component(ParticleEmitter.self, for: entity),
                  !emitter.particles.isEmpty
            else { continue }
            if canRenderEmitterParticlesOnGPU(emitter) {
                continue
            }
            let toWorld = world.worldTransform(for: entity)?.matrix ?? matrix_identity_float4x4
            if !isEmitterVisibleToCamera(emitter: emitter,
                                         toWorld: toWorld,
                                         camera: camera) {
                continue
            }
            let distanceFade = renderDistanceFade(emitter: emitter,
                                                  toWorld: toWorld,
                                                  cameraEye: camera.eye)
            if distanceFade <= 0 {
                continue
            }
            let cameraDistance = emitterCameraDistance(emitter: emitter,
                                                       toWorld: toWorld,
                                                       cameraEye: camera.eye)
            let sourceParticles = renderSourceParticles(for: emitter,
                                                        cameraDistance: cameraDistance)
            sourceParticleCount += emitter.particles.count
            submittedSourceParticleCount += sourceParticles.count
            if emitter.settings.renderer.renderMode == .ribbon {
                appendRibbonParticles(sourceParticles,
                                      emitter: emitter,
                                      toWorld: toWorld,
                                      distanceFade: distanceFade,
                                      cameraEye: camera.eye,
                                      nextSourceOrder: &nextSourceOrder,
                                      to: &sortableParticles)
                continue
            }
            let trailSegments = emitter.settings.trails.trailLength > 0 ? emitter.settings.trails.trailSegments : 0
            sortableParticles.reserveCapacity(sortableParticles.count + sourceParticles.count * (1 + trailSegments))
            for particle in sourceParticles {
                let sample = renderParticleSample(for: particle,
                                                  emitter: emitter,
                                                  toWorld: toWorld)
                let uvRect = emitter.textureUVRect(for: particle)
                let alignment = renderAlignment(for: emitter, worldVelocity: sample.velocity)
                var color = particle.color
                color.w *= distanceFade
                let base = RenderParticle(
                    position: sample.position,
                    size: particle.size,
                    rotation: particle.rotation,
                    color: color,
                    uvRect: uvRect,
                    alignmentAxis: alignment.axis,
                    stretch: alignment.stretch,
                    blendMode: emitter.settings.appearance.blendMode,
                    texturePath: emitter.settings.textureSheet.texturePath
                )
                appendSortableParticle(base,
                                       emitter: emitter,
                                       cameraEye: camera.eye,
                                       age: particle.age,
                                       nextSourceOrder: &nextSourceOrder,
                                       to: &sortableParticles)
                appendTrailParticles(for: particle,
                                     emitter: emitter,
                                     base: base,
                                     worldVelocity: sample.velocity,
                                     cameraEye: camera.eye,
                                     nextSourceOrder: &nextSourceOrder,
                                     to: &sortableParticles)
            }
        }
        sortableParticles.sort(by: compareSortableParticles)
        return CollectedRenderParticles(
            particles: sortableParticles.map(\.particle),
            sourceParticleCount: sourceParticleCount,
            submittedSourceParticleCount: submittedSourceParticleCount
        )
    }

    func renderSourceParticles(
        for emitter: ParticleEmitter,
        cameraDistance: Float
    ) -> ArraySlice<Particle> {
        let budget = emitter.effectiveMaxRenderedParticles(cameraDistance: cameraDistance,
                                                           liveParticleCount: emitter.particles.count)
        guard budget > 0 else {
            return emitter.particles[emitter.particles.endIndex...]
        }
        guard budget < emitter.particles.count else {
            return emitter.particles[...]
        }
        return emitter.particles.suffix(budget)
    }

    func appendSortableParticle(
        _ particle: RenderParticle,
        emitter: ParticleEmitter,
        cameraEye: SIMD3<Float>,
        age: Float,
        nextSourceOrder: inout Int,
        to result: inout [SortableRenderParticle]
    ) {
        result.append(
            SortableRenderParticle(
                particle: particle,
                sortMode: emitter.settings.renderer.sortMode,
                sortPriority: emitter.settings.renderer.renderSortPriority,
                distanceSquared: simd_length_squared(particle.position - cameraEye),
                age: max(0, age),
                sourceOrder: nextSourceOrder
            )
        )
        nextSourceOrder += 1
    }

    func compareSortableParticles(
        _ lhs: SortableRenderParticle,
        _ rhs: SortableRenderParticle
    ) -> Bool {
        if lhs.sortPriority != rhs.sortPriority {
            return lhs.sortPriority < rhs.sortPriority
        }
        if lhs.sortMode != rhs.sortMode {
            return tieBreakSortableParticles(lhs, rhs)
        }

        switch lhs.sortMode {
        case .distanceDescending:
            if lhs.distanceSquared != rhs.distanceSquared {
                return lhs.distanceSquared > rhs.distanceSquared
            }
        case .distanceAscending:
            if lhs.distanceSquared != rhs.distanceSquared {
                return lhs.distanceSquared < rhs.distanceSquared
            }
        case .oldestFirst:
            if lhs.age != rhs.age {
                return lhs.age > rhs.age
            }
        case .youngestFirst:
            if lhs.age != rhs.age {
                return lhs.age < rhs.age
            }
        }
        return tieBreakSortableParticles(lhs, rhs)
    }

    func tieBreakSortableParticles(
        _ lhs: SortableRenderParticle,
        _ rhs: SortableRenderParticle
    ) -> Bool {
        if lhs.distanceSquared != rhs.distanceSquared {
            return lhs.distanceSquared > rhs.distanceSquared
        }
        return lhs.sourceOrder < rhs.sourceOrder
    }

    struct CameraBasis {
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
    }

    struct RenderParticleSample {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
    }

    struct RibbonControlPoint {
        var particle: Particle
        var position: SIMD3<Float>
        var width: Float
        var color: SIMD4<Float>
    }

    struct RibbonRenderSegment {
        var startPosition: SIMD3<Float>
        var endPosition: SIMD3<Float>
        var startWidth: Float
        var endWidth: Float
        var startColor: SIMD4<Float>
        var endColor: SIMD4<Float>
        var sortAge: Float
        var uvRect: SIMD4<Float>
        var textureVOffset: Float
        var textureVScale: Float
        var runID: Int
    }

    func isEmitterVisibleToCamera(
        emitter: ParticleEmitter,
        toWorld: simd_float4x4,
        camera: RenderCamera
    ) -> Bool {
        let radius = emitter.effectiveRenderBoundsRadius()
        guard radius > 0 else {
            return true
        }
        let center = Self.transformPoint(emitter.settings.shape.originOffset, by: toWorld)
        let basis = cameraBasis(for: camera)
        let offset = center - camera.eye
        let forwardDistance = simd_dot(offset, basis.forward)

        if forwardDistance + radius < camera.near {
            return false
        }
        if camera.far > camera.near,
           forwardDistance - radius > camera.far {
            return false
        }

        let verticalHalfFov = max(0.001, min(Float.pi * 0.49, camera.fovYRadians * 0.5))
        let verticalHalfExtent = max(0, forwardDistance) * Float(tan(Double(verticalHalfFov))) + radius
        let verticalDistance = abs(simd_dot(offset, basis.up))
        if verticalDistance > verticalHalfExtent {
            return false
        }
        let horizontalHalfExtent = max(0, forwardDistance)
            * Float(tan(Double(verticalHalfFov)))
            * max(0.001, camera.aspectRatio)
            + radius
        let horizontalDistance = abs(simd_dot(offset, basis.right))
        if horizontalDistance > horizontalHalfExtent {
            return false
        }
        return true
    }

    func cameraBasis(for camera: RenderCamera) -> CameraBasis {
        let rawForward = camera.target - camera.eye
        let forward = normalizedOrDefault(rawForward, SIMD3<Float>(0, 0, -1))
        let requestedUp = normalizedOrDefault(camera.up, SIMD3<Float>(0, 1, 0))
        var right = simd_cross(forward, requestedUp)
        if simd_length_squared(right) <= 0.000_001 {
            right = simd_cross(forward, SIMD3<Float>(1, 0, 0))
        }
        right = normalizedOrDefault(right, SIMD3<Float>(1, 0, 0))
        let up = normalizedOrDefault(simd_cross(right, forward), SIMD3<Float>(0, 1, 0))
        return CameraBasis(forward: forward, right: right, up: up)
    }

    func renderDistanceFade(
        emitter: ParticleEmitter,
        toWorld: simd_float4x4,
        cameraEye: SIMD3<Float>
    ) -> Float {
        guard emitter.settings.renderer.maxRenderDistance > 0 else {
            return 1
        }
        let origin = Self.transformPoint(emitter.settings.shape.originOffset, by: toWorld)
        let distance = simd_length(origin - cameraEye)
        guard distance <= emitter.settings.renderer.maxRenderDistance else {
            return 0
        }
        guard emitter.settings.renderer.renderDistanceFadeRange > 0 else {
            return 1
        }
        let fadeRange = min(emitter.settings.renderer.renderDistanceFadeRange, emitter.settings.renderer.maxRenderDistance)
        guard fadeRange > 0.0001 else {
            return 1
        }
        let fadeStart = emitter.settings.renderer.maxRenderDistance - fadeRange
        guard distance > fadeStart else {
            return 1
        }
        return simd_clamp((emitter.settings.renderer.maxRenderDistance - distance) / fadeRange, 0, 1)
    }

    func emitterCameraDistance(
        emitter: ParticleEmitter,
        toWorld: simd_float4x4,
        cameraEye: SIMD3<Float>
    ) -> Float {
        let origin = Self.transformPoint(emitter.settings.shape.originOffset, by: toWorld)
        return simd_length(origin - cameraEye)
    }

    func appendTrailParticles(
        for particle: Particle,
        emitter: ParticleEmitter,
        base: RenderParticle,
        worldVelocity: SIMD3<Float>,
        cameraEye: SIMD3<Float>,
        nextSourceOrder: inout Int,
        to result: inout [SortableRenderParticle]
    ) {
        guard emitter.settings.trails.trailLength > 0,
              emitter.settings.trails.trailSegments > 0,
              particle.size > 0
        else { return }

        let speed = simd_length(worldVelocity)
        guard speed > 0.0001 else { return }

        let segmentCount = emitter.settings.trails.trailSegments
        let step = worldVelocity * (emitter.settings.trails.trailLength / Float(segmentCount))
        for index in 1...segmentCount {
            let t = Float(index) / Float(segmentCount)
            let sizeScale = 1 + (emitter.settings.trails.trailEndSizeScale - 1) * t
            let alphaScale = 1 + (emitter.settings.trails.trailEndAlphaScale - 1) * t
            var color = base.color
            color.w *= alphaScale
            appendSortableParticle(
                RenderParticle(
                    position: base.position - step * Float(index),
                    size: max(0, base.size * sizeScale),
                    rotation: base.rotation,
                    color: color,
                    uvRect: base.uvRect,
                    alignmentAxis: base.alignmentAxis,
                    stretch: base.stretch,
                    blendMode: base.blendMode,
                    texturePath: base.texturePath
                ),
                emitter: emitter,
                cameraEye: cameraEye,
                age: particle.age,
                nextSourceOrder: &nextSourceOrder,
                to: &result
            )
        }
    }

    func appendRibbonParticles(
        _ particles: ArraySlice<Particle>,
        emitter: ParticleEmitter,
        toWorld: simd_float4x4,
        distanceFade: Float,
        cameraEye: SIMD3<Float>,
        nextSourceOrder: inout Int,
        to result: inout [SortableRenderParticle]
    ) {
        guard particles.count >= 2 else { return }

        let samples = particles.map { particle in
            (particle: particle, sample: renderParticleSample(for: particle,
                                                              emitter: emitter,
                                                              toWorld: toWorld))
        }
        let segmentLengths = zip(samples.dropLast(), samples.dropFirst()).map { (start, end) in
            simd_length(end.sample.position - start.sample.position)
        }
        let segmentCount = max(1, segmentLengths.count)
        let controlPoints = samples.enumerated().map { index, pair in
            let tailNormalized = 1 - simd_clamp(Float(index) / Float(segmentCount), 0, 1)
            let widthScale = emitter.settings.trails.ribbonWidthScale
                * (1 + (emitter.settings.trails.ribbonTailWidthScale - 1) * tailNormalized)
            let alphaScale = 1 + (emitter.settings.trails.ribbonTailAlphaScale - 1) * tailNormalized
            var color = pair.particle.color
            color.w *= distanceFade * alphaScale
            return RibbonControlPoint(
                particle: pair.particle,
                position: pair.sample.position,
                width: max(0, pair.particle.size * widthScale),
                color: color
            )
        }

        let subdivisions = emitter.settings.trails.ribbonSmoothingSegments
        var drafts: [RibbonRenderSegment] = []
        drafts.reserveCapacity(max(0, segmentLengths.count * subdivisions))
        var ribbonDistance: Float = 0
        var runID = 0
        for index in segmentLengths.indices {
            let length = segmentLengths[index]
            guard isRenderableRibbonSegment(length, emitter: emitter) else {
                ribbonDistance = 0
                runID += 1
                continue
            }

            let previousPosition = connectedRibbonControlPosition(index - 1,
                                                                  fallback: controlPoints[index].position,
                                                                  segmentLengths: segmentLengths,
                                                                  controlPoints: controlPoints,
                                                                  emitter: emitter)
            let nextPosition = connectedRibbonControlPosition(index + 2,
                                                              fallback: controlPoints[index + 1].position,
                                                              segmentLengths: segmentLengths,
                                                              controlPoints: controlPoints,
                                                              emitter: emitter)
            for subdivision in 0..<subdivisions {
                let t0 = Float(subdivision) / Float(subdivisions)
                let t1 = Float(subdivision + 1) / Float(subdivisions)
                let startPosition = ribbonInterpolatedPosition(previous: previousPosition,
                                                               start: controlPoints[index].position,
                                                               end: controlPoints[index + 1].position,
                                                               next: nextPosition,
                                                               t: t0,
                                                               smooth: subdivisions > 1)
                let endPosition = ribbonInterpolatedPosition(previous: previousPosition,
                                                             start: controlPoints[index].position,
                                                             end: controlPoints[index + 1].position,
                                                             next: nextPosition,
                                                             t: t1,
                                                             smooth: subdivisions > 1)
                let subLength = simd_length(endPosition - startPosition)
                guard subLength > 0.0001 else { continue }
                let startWidth = lerp(controlPoints[index].width, controlPoints[index + 1].width, t0)
                let endWidth = lerp(controlPoints[index].width, controlPoints[index + 1].width, t1)
                let startColor = lerp(controlPoints[index].color, controlPoints[index + 1].color, t0)
                let endColor = lerp(controlPoints[index].color, controlPoints[index + 1].color, t1)
                let sortAge = lerp(controlPoints[index].particle.age, controlPoints[index + 1].particle.age, (t0 + t1) * 0.5)
                drafts.append(
                    RibbonRenderSegment(
                        startPosition: startPosition,
                        endPosition: endPosition,
                        startWidth: startWidth,
                        endWidth: endWidth,
                        startColor: startColor,
                        endColor: endColor,
                        sortAge: sortAge,
                        uvRect: emitter.textureUVRect(for: controlPoints[index].particle),
                        textureVOffset: emitter.settings.trails.ribbonTextureOffset + ribbonDistance * emitter.settings.trails.ribbonTextureTiling,
                        textureVScale: subLength * emitter.settings.trails.ribbonTextureTiling,
                        runID: runID
                    )
                )
                ribbonDistance += subLength
            }
        }

        let renderSegmentLengths = drafts.map { simd_length($0.endPosition - $0.startPosition) }
        let runIDs = drafts.map(\.runID)
        result.reserveCapacity(result.count + drafts.count)
        for (index, draft) in drafts.enumerated() {
            let length = renderSegmentLengths[index]
            guard length > 0.0001 else { continue }
            let width = max(0.0001, max(draft.startWidth, draft.endWidth))
            let startOverlap = ribbonJoinOverlap(segmentIndex: index,
                                                 neighborIndex: index - 1,
                                                 width: width,
                                                 segmentLengths: renderSegmentLengths,
                                                 runIDs: runIDs,
                                                 emitter: emitter)
            let endOverlap = ribbonJoinOverlap(segmentIndex: index,
                                               neighborIndex: index + 1,
                                               width: width,
                                               segmentLengths: renderSegmentLengths,
                                               runIDs: runIDs,
                                               emitter: emitter)
            let direction = (draft.endPosition - draft.startPosition) / length
            let renderLength = length + startOverlap + endOverlap
            let renderCenter = (draft.startPosition + draft.endPosition) * 0.5
                + direction * ((endOverlap - startOverlap) * 0.5)
            appendSortableParticle(
                RenderParticle(
                    position: renderCenter,
                    size: width,
                    rotation: 0,
                    color: draft.startColor,
                    endColor: draft.endColor,
                    uvRect: draft.uvRect,
                    alignmentAxis: direction,
                    stretch: max(1, renderLength / width),
                    startSize: draft.startWidth,
                    endSize: draft.endWidth,
                    shape: .ribbonSegment,
                    textureVOffset: draft.textureVOffset,
                    textureVScale: draft.textureVScale,
                    blendMode: emitter.settings.appearance.blendMode,
                    texturePath: emitter.settings.textureSheet.texturePath
                ),
                emitter: emitter,
                cameraEye: cameraEye,
                age: draft.sortAge,
                nextSourceOrder: &nextSourceOrder,
                to: &result
            )
        }
    }

    func ribbonJoinOverlap(
        segmentIndex: Int,
        neighborIndex: Int,
        width: Float,
        segmentLengths: [Float],
        runIDs: [Int],
        emitter: ParticleEmitter
    ) -> Float {
        guard emitter.settings.trails.ribbonJoinOverlapScale > 0,
              segmentLengths.indices.contains(segmentIndex),
              segmentLengths.indices.contains(neighborIndex),
              runIDs.indices.contains(segmentIndex),
              runIDs.indices.contains(neighborIndex),
              runIDs[segmentIndex] == runIDs[neighborIndex]
        else { return 0 }
        let length = segmentLengths[segmentIndex]
        let neighborLength = segmentLengths[neighborIndex]
        guard length > 0.0001, neighborLength > 0.0001 else { return 0 }
        return min(width * emitter.settings.trails.ribbonJoinOverlapScale,
                   length * 0.5,
                   neighborLength * 0.5)
    }

    func connectedRibbonControlPosition(
        _ pointIndex: Int,
        fallback: SIMD3<Float>,
        segmentLengths: [Float],
        controlPoints: [RibbonControlPoint],
        emitter: ParticleEmitter
    ) -> SIMD3<Float> {
        guard controlPoints.indices.contains(pointIndex) else {
            return fallback
        }
        if pointIndex < controlPoints.count - 1,
           !isRenderableRibbonSegment(segmentLengths[pointIndex], emitter: emitter) {
            return fallback
        }
        if pointIndex > 0,
           !isRenderableRibbonSegment(segmentLengths[pointIndex - 1], emitter: emitter) {
            return fallback
        }
        return controlPoints[pointIndex].position
    }

    func ribbonInterpolatedPosition(
        previous: SIMD3<Float>,
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        next: SIMD3<Float>,
        t: Float,
        smooth: Bool
    ) -> SIMD3<Float> {
        guard smooth else {
            return lerp(start, end, t)
        }
        let t2 = t * t
        let t3 = t2 * t
        let term0 = start * 2
        let term1 = (end - previous) * t
        let term2A = previous * 2
        let term2B = start * 5
        let term2C = end * 4
        let term2Base = term2A - term2B + term2C - next
        let term2 = term2Base * t2
        let term3A = start * 3
        let term3B = end * 3
        let term3Base = -previous + term3A - term3B + next
        let term3 = term3Base * t3
        return (term0 + term1 + term2 + term3) * 0.5
    }

    func lerp(_ start: Float, _ end: Float, _ t: Float) -> Float {
        start + (end - start) * t
    }

    func lerp(_ start: SIMD3<Float>, _ end: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        start + (end - start) * t
    }

    func lerp(_ start: SIMD4<Float>, _ end: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        start + (end - start) * t
    }

    func isRenderableRibbonSegment(_ length: Float, emitter: ParticleEmitter) -> Bool {
        guard length > 0.0001 else { return false }
        if emitter.settings.trails.ribbonMaxSegmentLength > 0,
           length > emitter.settings.trails.ribbonMaxSegmentLength {
            return false
        }
        return true
    }

    func renderAlignment(for emitter: ParticleEmitter,
                                 worldVelocity: SIMD3<Float>) -> (axis: SIMD3<Float>, stretch: Float) {
        guard emitter.settings.renderer.renderAlignment == .velocity else {
            return (.zero, 1)
        }
        let speed = simd_length(worldVelocity)
        guard speed > 0.0001 else {
            return (.zero, 1)
        }
        let stretch = min(emitter.settings.renderer.velocityStretchMax,
                          max(1, 1 + speed * emitter.settings.renderer.velocityStretchScale))
        return (worldVelocity / speed, stretch)
    }

    func renderParticleSample(for particle: Particle,
                                      emitter: ParticleEmitter,
                                      toWorld: simd_float4x4) -> RenderParticleSample {
        switch emitter.settings.gpuSimulation.simulationSpace {
        case .local:
            let worldPosition = Self.transformPoint(particle.position, by: toWorld)
            let worldVelocity = Self.transformDirection(particle.velocity, by: toWorld)
            return RenderParticleSample(position: worldPosition, velocity: worldVelocity)
        case .world:
            return RenderParticleSample(position: particle.position, velocity: particle.velocity)
        }
    }

    private static func transformDirection(_ direction: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(direction, 0)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    private static func transformPoint(_ point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(point, 1)
        if abs(transformed.w) > 0.0001 {
            return SIMD3<Float>(
                transformed.x / transformed.w,
                transformed.y / transformed.w,
                transformed.z / transformed.w
            )
        }
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}

private func normalizedOrDefault(_ vector: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
    let lengthSquared = simd_length_squared(vector)
    guard lengthSquared > 0.000_001 else {
        return fallback
    }
    return vector / sqrt(lengthSquared)
}
