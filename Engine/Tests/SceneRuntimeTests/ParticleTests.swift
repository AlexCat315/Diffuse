import SceneRuntime
import Testing
import Foundation
import SIMDCompat

@Suite("Particles")
struct ParticleTests {

    @Test("module stack mirrors and applies legacy emitter configuration")
    func moduleStackMirrorsAndAppliesLegacyEmitterConfiguration() throws {
        let emitter = ParticleEmitter(looping: false,
                                      duration: 4,
                                      emissionRate: 12,
                                      distanceEmissionRate: 3,
                                      burstCount: 2,
                                      maxParticles: 128,
                                      maxRenderedParticles: 32,
                                      lifetime: 1.5,
                                      subEmitters: [
                                          ParticleSubEmitter(trigger: .death,
                                                             burstCount: 2,
                                                             lifetime: 0.4,
                                                             startVelocity: SIMD3<Float>(1, 0, 0)),
                                      ],
                                      originOffset: SIMD3<Float>(0.5, 1, -0.5),
                                      spawnRadius: 2,
                                      emissionShape: .cone,
                                      coneRadius: 0.75,
                                      coneHeight: 3,
                                      startVelocity: SIMD3<Float>(1, 2, 3),
                                      velocityRandomness: SIMD3<Float>(0.1, 0.2, 0.3),
                                      velocityInheritance: 0.5,
                                      gravity: SIMD3<Float>(0, -2, 0),
                                      noiseStrength: 1.25,
                                      forceMode: .radial,
                                      forceRadius: 4,
                                      forceStrength: 6,
                                      vectorFieldMode: .curl,
                                      vectorFieldStrength: 2,
                                      collisionMode: .worldPlane,
                                      simulationSpace: .world,
                                      simulationBackend: .gpuIfSupported,
                                      gpuSimulationWorkgroupSize: 128,
                                      collisionRestitution: 0.8,
                                      collisionDamping: 0.2,
                                      startSize: 0.5,
                                      endSize: 0.1,
                                      sizeRandomness: 0.3,
                                      blendMode: .additive,
                                      renderMode: .ribbon,
                                      sortMode: .youngestFirst,
                                      renderAlignment: .velocity,
                                      velocityStretchScale: 0.4,
                                      maxRenderDistance: 80,
                                      textureAssetID: "texture-smoke",
                                      texturePath: "/tmp/smoke.png",
                                      textureSheetColumns: 4,
                                      textureSheetRows: 2,
                                      textureSheetFrameCount: 7,
                                      textureSheetFrameRate: 12,
                                      textureSheetPlaybackMode: .loop,
                                      textureSheetStartFrame: 3,
                                      textureSheetFrameRandomness: 2,
                                      trailLength: 0.75,
                                      trailSegments: 5,
                                      seed: 987_654_321)

        var stack = emitter.moduleStack

        #expect(stack.version == ParticleModuleStack.currentVersion)
        #expect(stack.modules.map(\.id) == [
            "emission",
            "shape",
            "velocity",
            "forces",
            "collision",
            "appearance",
            "textureSheet",
            "renderer",
            "trails",
            "subEmitters",
            "gpuSimulation",
        ])

        let emission = try #require(stack.modules.first { $0.id == "emission" })
        if case let .emission(settings) = emission.settings {
            #expect(settings.emissionRate == 12)
            #expect(settings.distanceEmissionRate == 3)
            #expect(settings.maxRenderedParticles == 32)
            #expect(settings.seed == 987_654_321)
        } else {
            Issue.record("expected emission module settings")
        }

        let textureSheet = try #require(stack.modules.first { $0.id == "textureSheet" })
        if case let .textureSheet(settings) = textureSheet.settings {
            #expect(settings.textureAssetID == "texture-smoke")
            #expect(settings.columns == 4)
            #expect(settings.rows == 2)
            #expect(settings.playbackMode == .loop)
            #expect(settings.startFrame == 3)
            #expect(settings.frameRandomness == 2)
        } else {
            Issue.record("expected texture sheet module settings")
        }

        try editModule(&stack, id: "emission") { settings in
            if case var .emission(module) = settings {
                module.emissionRate = -4
                module.maxParticles = -8
                module.seed = 42
                settings = .emission(module)
            }
        }
        try editModule(&stack, id: "collision") { settings in
            if case var .collision(module) = settings {
                module.collisionRestitution = 2
                module.collisionDamping = -1
                settings = .collision(module)
            }
        }
        try editModule(&stack, id: "textureSheet") { settings in
            if case var .textureSheet(module) = settings {
                module.textureAssetID = ""
                module.columns = 0
                module.rows = -2
                module.frameCount = 0
                module.playbackMode = .singleFrame
                module.frameRandomness = -3
                settings = .textureSheet(module)
            }
        }
        try editModule(&stack, id: "gpuSimulation") { settings in
            if case var .gpuSimulation(module) = settings {
                module.workgroupSize = 0
                settings = .gpuSimulation(module)
            }
        }

        var applied = ParticleEmitter()
        applied.apply(stack)

        #expect(applied.emissionRate == 0)
        #expect(applied.maxParticles == 0)
        #expect(applied.seed == 42)
        #expect(applied.collisionRestitution == 1)
        #expect(applied.collisionDamping == 0)
        #expect(applied.textureAssetID == nil)
        #expect(applied.textureSheetColumns == 1)
        #expect(applied.textureSheetRows == 1)
        #expect(applied.textureSheetFrameCount == 1)
        #expect(applied.textureSheetPlaybackMode == .singleFrame)
        #expect(applied.textureSheetFrameRandomness == 0)
        #expect(applied.gpuSimulationWorkgroupSize == 1)
    }

    @Test("module stack preserves disabled authored settings while rebasing enabled modules")
    func moduleStackPreservesDisabledAuthoredSettingsWhileRebasingEnabledModules() throws {
        var emitter = ParticleEmitter(gravity: SIMD3<Float>(0, -9.81, 0))
        var stack = emitter.moduleStack
        let forcesIndex = try #require(stack.modules.firstIndex { $0.id == "forces" })
        stack.modules[forcesIndex].isEnabled = false
        if case var .forces(settings) = stack.modules[forcesIndex].settings {
            settings.gravity = SIMD3<Float>(4, 5, 6)
            stack.modules[forcesIndex].settings = .forces(settings)
        } else {
            Issue.record("expected forces module settings")
        }

        emitter.apply(stack)
        emitter.emissionRate = 24
        emitter.gravity = SIMD3<Float>(1, 2, 3)

        let rebased = emitter.moduleStack
        let emission = try #require(rebased.modules.first { $0.id == "emission" })
        if case let .emission(settings) = emission.settings {
            #expect(settings.emissionRate == 24)
        } else {
            Issue.record("expected emission module settings")
        }
        let forces = try #require(rebased.modules.first { $0.id == "forces" })
        #expect(!forces.isEnabled)
        if case let .forces(settings) = forces.settings {
            #expect(settings.gravity == SIMD3<Float>(4, 5, 6))
        } else {
            Issue.record("expected forces module settings")
        }
    }

    @Test("module stack applies seed and reseeds the random stream")
    func moduleStackAppliesSeedAndReseedsRandomStream() throws {
        var applied = ParticleEmitter(emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 1,
                                      spawnRadius: 2,
                                      sizeRandomness: 0.5,
                                      textureSheetFrameRandomness: 3,
                                      seed: 1)
        var stack = applied.moduleStack
        try editModule(&stack, id: "emission") { settings in
            guard case var .emission(module) = settings else { return }
            module.seed = 77
            settings = .emission(module)
        }

        var expected = ParticleEmitter(emissionRate: 0,
                                       maxParticles: 8,
                                       lifetime: 1,
                                       spawnRadius: 2,
                                       sizeRandomness: 0.5,
                                       textureSheetFrameRandomness: 3,
                                       seed: 77)
        applied.apply(stack)
        applied.emit(4)
        expected.emit(4)

        #expect(applied.seed == 77)
        #expect(applied.particles == expected.particles)
    }

    @Test("module stack preserves custom order and reset restores default authoring")
    func moduleStackPreservesCustomOrderAndResetsAuthoring() throws {
        var emitter = ParticleEmitter()
        var stack = emitter.moduleStack
        let textureSheetIndex = try #require(stack.modules.firstIndex { $0.id == "textureSheet" })
        stack.moveModule(from: textureSheetIndex, to: 0)
        stack.modules[0].isEnabled = false

        emitter.apply(stack)

        #expect(emitter.moduleStack.modules.first?.id == "textureSheet")
        #expect(emitter.moduleStack.modules.first?.isEnabled == false)

        var reset = emitter.moduleStack
        reset.resetAuthoringState()

        #expect(reset.modules.map(\.id) == ParticleModuleStack.defaultModuleIDs)
        #expect(reset.modules.allSatisfy { $0.isEnabled })
        #expect(reset.modules.allSatisfy { !$0.isExpanded })
    }

    @Test("module stack validation reports authoring issues before runtime clamping")
    func moduleStackValidationReportsAuthoringIssues() throws {
        var emitter = ParticleEmitter(emissionRate: 8,
                                      maxParticles: 64,
                                      lifetime: 1,
                                      simulationBackend: .gpuRequired)
        var stack = emitter.moduleStack
        try editModule(&stack, id: "emission") { settings in
            guard case var .emission(module) = settings else { return }
            module.isEmitting = true
            module.emissionRate = 0
            module.distanceEmissionRate = 0
            module.burstCount = 0
            module.maxParticles = 0
            module.simulationSpeed = -1
            settings = .emission(module)
        }
        try editModule(&stack, id: "appearance") { settings in
            guard case var .appearance(module) = settings else { return }
            module.lifetime = 0
            settings = .appearance(module)
        }
        try editModule(&stack, id: "textureSheet") { settings in
            guard case var .textureSheet(module) = settings else { return }
            module.columns = 2
            module.rows = 2
            module.frameCount = 8
            settings = .textureSheet(module)
        }
        try editModule(&stack, id: "renderer") { settings in
            guard case var .renderer(module) = settings else { return }
            module.velocityStretchScale = -1
            module.velocityStretchMax = 0
            module.maxRenderDistance = 10
            module.renderDistanceFadeRange = 20
            module.renderLODStartDistance = 30
            module.renderLODEndDistance = 10
            module.renderLODMinParticleScale = 1.5
            module.renderBoundsMode = .manual
            module.renderBoundsRadius = -1
            settings = .renderer(module)
        }
        try editModule(&stack, id: "trails") { settings in
            guard case var .trails(module) = settings else { return }
            module.trailLength = -1
            module.trailSegments = -2
            module.ribbonSmoothingSegments = 0
            module.ribbonTailAlphaScale = 2
            module.ribbonWidthScale = -1
            module.ribbonMaxSegmentLength = -4
            module.ribbonTextureTiling = -1
            module.trailEndSizeScale = -0.5
            module.trailEndAlphaScale = -0.25
            settings = .trails(module)
        }
        try editModule(&stack, id: "gpuSimulation") { settings in
            guard case var .gpuSimulation(module) = settings else { return }
            module.workgroupSize = ParticleGPUSimulationPlan.maximumWorkgroupSize + 1
            settings = .gpuSimulation(module)
        }

        let stackIssueCodes = stack.validationIssues().map(\.code)

        #expect(stackIssueCodes.contains("noParticleCapacity"))
        #expect(stackIssueCodes.contains("noSpawnSource"))
        #expect(stackIssueCodes.contains("negativeSimulationSpeed"))
        #expect(stackIssueCodes.contains("invalidLifetime"))
        #expect(stackIssueCodes.contains("frameCountExceedsCells"))
        #expect(stackIssueCodes.contains("negativeVelocityStretch"))
        #expect(stackIssueCodes.contains("fadeRangeExceedsDistance"))
        #expect(stackIssueCodes.contains("invalidLODRange"))
        #expect(stackIssueCodes.contains("lodScaleOutOfRange"))
        #expect(stackIssueCodes.contains("negativeRenderBoundsRadius"))
        #expect(stackIssueCodes.contains("negativeTrailSettings"))
        #expect(stackIssueCodes.contains("invalidRibbonSmoothing"))
        #expect(stackIssueCodes.contains("tailAlphaOutOfRange"))
        #expect(stackIssueCodes.contains("negativeRibbonWidth"))
        #expect(stackIssueCodes.contains("negativeRibbonSegment"))
        #expect(stackIssueCodes.contains("negativeRibbonTiling"))
        #expect(stackIssueCodes.contains("negativeTrailEndSize"))
        #expect(stackIssueCodes.contains("trailEndAlphaOutOfRange"))
        #expect(stackIssueCodes.contains("gpuWorkgroupClamped"))

        emitter.apply(stack)
        let emitterIssues = emitter.moduleValidationIssues

        #expect(emitterIssues.contains {
            $0.moduleID == "gpuSimulation" && $0.code == "gpuRequiredButUnsupported"
        })

        stack.repairValidationIssues()
        let repairedIssueCodes = stack.validationIssues().map(\.code)

        #expect(!repairedIssueCodes.contains("noParticleCapacity"))
        #expect(!repairedIssueCodes.contains("negativeSimulationSpeed"))
        #expect(repairedIssueCodes.contains("noSpawnSource"))
        #expect(!repairedIssueCodes.contains("invalidLifetime"))
        #expect(!repairedIssueCodes.contains("frameCountExceedsCells"))
        #expect(!repairedIssueCodes.contains("negativeVelocityStretch"))
        #expect(!repairedIssueCodes.contains("fadeRangeExceedsDistance"))
        #expect(!repairedIssueCodes.contains("invalidLODRange"))
        #expect(!repairedIssueCodes.contains("lodScaleOutOfRange"))
        #expect(!repairedIssueCodes.contains("negativeRenderBoundsRadius"))
        #expect(!repairedIssueCodes.contains("negativeTrailSettings"))
        #expect(!repairedIssueCodes.contains("invalidRibbonSmoothing"))
        #expect(!repairedIssueCodes.contains("tailAlphaOutOfRange"))
        #expect(!repairedIssueCodes.contains("negativeRibbonWidth"))
        #expect(!repairedIssueCodes.contains("negativeRibbonSegment"))
        #expect(!repairedIssueCodes.contains("negativeRibbonTiling"))
        #expect(!repairedIssueCodes.contains("negativeTrailEndSize"))
        #expect(!repairedIssueCodes.contains("trailEndAlphaOutOfRange"))
        #expect(!repairedIssueCodes.contains("gpuWorkgroupClamped"))

        emitter.apply(stack)
        #expect(!emitter.moduleValidationIssues.contains {
            $0.moduleID == "gpuSimulation" && $0.code == "gpuRequiredButUnsupported"
        })
    }

    @Test("module stack repair removes duplicate modules and restores missing defaults")
    func moduleStackRepairNormalizesTopology() throws {
        var stack = ParticleEmitter().moduleStack
        let emission = try #require(stack.modules.first { $0.id == "emission" })
        stack.modules[0].displayName = "Legacy Emission"
        stack.modules[0].stage = .render
        stack.modules[0].isEnabled = false
        stack.modules.insert(emission, at: 1)
        stack.modules.removeAll { $0.id == "trails" }

        let issueCodes = stack.validationIssues().map(\.code)
        #expect(issueCodes.contains("duplicateModule"))
        #expect(issueCodes.contains("missingModule"))

        stack.repairValidationIssues()

        let repairedIssueCodes = stack.validationIssues().map(\.code)
        #expect(!repairedIssueCodes.contains("duplicateModule"))
        #expect(!repairedIssueCodes.contains("missingModule"))
        #expect(stack.version == ParticleModuleStack.currentVersion)
        #expect(stack.modules.filter { $0.id == "emission" }.count == 1)
        #expect(stack.modules.filter { $0.id == "trails" }.count == 1)
        #expect(Set(stack.modules.map(\.id)).isSuperset(of: ParticleModuleStack.defaultModuleIDs))

        let repairedEmission = try #require(stack.modules.first { $0.id == "emission" })
        #expect(repairedEmission.displayName == "Emission")
        #expect(repairedEmission.stage == .spawn)
        #expect(!repairedEmission.isEnabled)

        let repairedTrails = try #require(stack.modules.first { $0.id == "trails" })
        #expect(repairedTrails.displayName == "Trails")
        #expect(repairedTrails.isEnabled)
    }

    @Test("module stack can repair a single authored module")
    func moduleStackRepairsSingleModule() throws {
        var stack = ParticleEmitter().moduleStack
        try editModule(&stack, id: "emission") { settings in
            guard case var .emission(module) = settings else { return }
            module.maxParticles = 0
            module.simulationSpeed = -1
            settings = .emission(module)
        }
        try editModule(&stack, id: "renderer") { settings in
            guard case var .renderer(module) = settings else { return }
            module.velocityStretchScale = -1
            module.renderLODStartDistance = 20
            module.renderLODEndDistance = 10
            settings = .renderer(module)
        }

        stack.repairValidationIssues(for: "renderer")
        let issueCodes = stack.validationIssues().map(\.code)

        #expect(issueCodes.contains("noParticleCapacity"))
        #expect(issueCodes.contains("negativeSimulationSpeed"))
        #expect(!issueCodes.contains("negativeVelocityStretch"))
        #expect(!issueCodes.contains("invalidLODRange"))
    }

    @Test("module stack can reset a single module to default settings")
    func moduleStackResetsSingleModuleSettings() throws {
        var stack = ParticleEmitter().moduleStack
        let rendererIndex = try #require(stack.modules.firstIndex { $0.id == "renderer" })
        stack.modules[rendererIndex].isEnabled = false
        stack.modules[rendererIndex].isExpanded = true
        if case var .renderer(module) = stack.modules[rendererIndex].settings {
            module.renderMode = .ribbon
            module.renderSortPriority = 42
            module.renderBoundsMode = .manual
            module.renderBoundsRadius = 99
            stack.modules[rendererIndex].settings = .renderer(module)
        } else {
            Issue.record("expected renderer module settings")
        }

        #expect(stack.moduleSettingsDifferFromDefault("renderer"))
        stack.resetModuleSettings(for: "renderer")

        let resetRenderer = try #require(stack.modules.first { $0.id == "renderer" })
        let defaultRenderer = try #require(ParticleModuleStack(emitter: ParticleEmitter()).modules.first { $0.id == "renderer" })
        #expect(!resetRenderer.isEnabled)
        #expect(resetRenderer.isExpanded)
        #expect(resetRenderer.stage == defaultRenderer.stage)
        #expect(resetRenderer.displayName == defaultRenderer.displayName)
        #expect(resetRenderer.settings == defaultRenderer.settings)
        #expect(!stack.moduleSettingsDifferFromDefault("renderer"))
    }

    @Test("module stack reports modules modified from defaults")
    func moduleStackReportsModifiedModules() throws {
        var stack = ParticleEmitter().moduleStack
        #expect(stack.modifiedModuleIDs.isEmpty)

        try editModule(&stack, id: "emission") { settings in
            guard case var .emission(module) = settings else { return }
            module.emissionRate = 123
            settings = .emission(module)
        }
        try editModule(&stack, id: "renderer") { settings in
            guard case var .renderer(module) = settings else { return }
            module.renderSortPriority = 5
            settings = .renderer(module)
        }

        #expect(stack.modifiedModuleIDs == ["emission", "renderer"])
        stack.resetModuleSettings(for: "emission")
        #expect(stack.modifiedModuleIDs == ["renderer"])
        stack.resetModuleSettings(for: "renderer")
        #expect(stack.modifiedModuleIDs.isEmpty)
    }

    @Test("module modified state ignores enabled and expansion authoring flags")
    func moduleModifiedStateIgnoresEnabledAndExpansionFlags() throws {
        var stack = ParticleEmitter().moduleStack
        let rendererIndex = try #require(stack.modules.firstIndex { $0.id == "renderer" })

        stack.modules[rendererIndex].isEnabled = false
        stack.modules[rendererIndex].isExpanded = true

        #expect(!stack.moduleSettingsDifferFromDefault("renderer"))
        #expect(stack.modifiedModuleIDs.isEmpty)
    }

    @Test("module stack can focus modified and invalid modules")
    func moduleStackCanFocusModifiedAndInvalidModules() throws {
        var stack = ParticleEmitter().moduleStack
        try editModule(&stack, id: "emission") { settings in
            guard case var .emission(module) = settings else { return }
            module.emissionRate = 123
            settings = .emission(module)
        }
        try editModule(&stack, id: "renderer") { settings in
            guard case var .renderer(module) = settings else { return }
            module.renderLODStartDistance = 40
            module.renderLODEndDistance = 10
            settings = .renderer(module)
        }

        stack.expandModifiedModules(collapseOthers: true)
        #expect(stack.expandedModuleIDs == ["emission", "renderer"])

        stack.collapseAllModules()
        #expect(stack.expandedModuleIDs.isEmpty)

        let focusedIssueIDs = stack.expandModulesWithValidationIssues(collapseOthers: true)
        #expect(focusedIssueIDs == ["renderer"])
        #expect(stack.expandedModuleIDs == ["renderer"])
    }

    @Test("continuous emission spawns at the configured rate")
    func continuousEmission() {
        var emitter = ParticleEmitter(emissionRate: 10, maxParticles: 1000, lifetime: 1000,
                                      startVelocity: .zero, gravity: .zero)
        for _ in 0..<10 { emitter.advance(deltaTime: 0.1) } // 10 * (10/s * 0.1s) = 10
        #expect(emitter.aliveCount == 10)
    }

    @Test("simulation speed scales particle aging and emission")
    func simulationSpeedScalesAgingAndEmission() {
        var slow = ParticleEmitter(simulationSpeed: 0.5,
                                   emissionRate: 10,
                                   maxParticles: 100,
                                   lifetime: 100,
                                   startVelocity: .zero,
                                   gravity: .zero)
        slow.advance(deltaTime: 1)
        #expect(slow.aliveCount == 5)
        #expect(slow.lastFrameStats.simulatedDeltaTime == 0.5)

        var fast = ParticleEmitter(simulationSpeed: 2,
                                   emissionRate: 10,
                                   maxParticles: 100,
                                   lifetime: 100,
                                   startVelocity: .zero,
                                   gravity: .zero)
        fast.advance(deltaTime: 1)
        #expect(fast.aliveCount == 20)
        #expect(fast.lastFrameStats.simulatedDeltaTime == 2)
    }

    @Test("zero simulation speed pauses particle aging and distance emission")
    func zeroSimulationSpeedPausesParticles() {
        var emitter = ParticleEmitter(simulationSpeed: 0,
                                      emissionRate: 0,
                                      distanceEmissionRate: 10,
                                      maxParticles: 100,
                                      lifetime: 10,
                                      startVelocity: SIMD3<Float>(1, 0, 0),
                                      gravity: .zero)
        emitter.emit(1)
        var start = matrix_identity_float4x4
        start.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        emitter.advance(deltaTime: 1, worldTransform: start)

        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4<Float>(5, 0, 0, 1)
        emitter.advance(deltaTime: 1, worldTransform: moved)

        #expect(emitter.aliveCount == 1)
        #expect(emitter.particles[0].age == 0)
        #expect(emitter.particles[0].position == .zero)
        #expect(emitter.lastFrameStats.simulatedDeltaTime == 0)
        #expect(emitter.lastFrameStats.distanceSpawnedCount == 0)
    }

    @Test("frame spawned particles track accepted advance emissions")
    func frameSpawnedParticlesTrackAcceptedAdvanceEmissions() {
        var emitter = ParticleEmitter(emissionRate: 10,
                                      maxParticles: 1,
                                      lifetime: 100,
                                      startVelocity: .zero,
                                      gravity: .zero)

        emitter.advance(deltaTime: 0.2)

        #expect(emitter.aliveCount == 1)
        #expect(emitter.lastFrameStats.continuousSpawnedCount == 1)
        #expect(emitter.lastFrameStats.capacityLimitedSpawnCount == 1)
        #expect(emitter.lastFrameSpawnedParticles.count == 1)

        emitter.isEmitting = false
        emitter.advance(deltaTime: 0.1)

        #expect(emitter.aliveCount == 1)
        #expect(emitter.lastFrameStats.spawnedParticleCount == 0)
        #expect(emitter.lastFrameSpawnedParticles.isEmpty)
    }

    @Test("scheduled bursts spawn particles at configured intervals")
    func scheduledBursts() {
        var emitter = ParticleEmitter(emissionRate: 0, burstCount: 3, burstInterval: 0.5,
                                      maxParticles: 100, lifetime: 100,
                                      startVelocity: .zero, gravity: .zero)
        emitter.advance(deltaTime: 0.49)
        #expect(emitter.aliveCount == 0)
        emitter.advance(deltaTime: 0.01)
        #expect(emitter.aliveCount == 3)
        emitter.advance(deltaTime: 1.0)
        #expect(emitter.aliveCount == 9)
    }

    @Test("distance emission spawns particles after the emitter moves")
    func distanceEmission() {
        var start = matrix_identity_float4x4
        start.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4<Float>(1, 0, 0, 1)
        var emitter = ParticleEmitter(emissionRate: 0,
                                      distanceEmissionRate: 4,
                                      maxParticles: 16,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      simulationSpace: .world)

        emitter.advance(deltaTime: 0.1, worldTransform: start)
        #expect(emitter.aliveCount == 0)

        emitter.advance(deltaTime: 0.1, worldTransform: moved)
        #expect(emitter.aliveCount == 4)
        #expect(emitter.particles.map(\.position.x) == [0.125, 0.375, 0.625, 0.875])
    }

    @Test("distance emission carries fractional movement between frames")
    func distanceEmissionAccumulator() {
        var start = matrix_identity_float4x4
        var moved = matrix_identity_float4x4
        var emitter = ParticleEmitter(emissionRate: 0,
                                      distanceEmissionRate: 2,
                                      maxParticles: 16,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      simulationSpace: .world)

        emitter.advance(deltaTime: 0.1, worldTransform: start)
        moved.columns.3 = SIMD4<Float>(0.25, 0, 0, 1)
        emitter.advance(deltaTime: 0.1, worldTransform: moved)
        #expect(emitter.aliveCount == 0)

        start.columns.3 = SIMD4<Float>(0.5, 0, 0, 1)
        emitter.advance(deltaTime: 0.1, worldTransform: start)
        #expect(emitter.aliveCount == 1)
    }

    @Test("spawned particles can inherit emitter velocity")
    func velocityInheritance() {
        let start = matrix_identity_float4x4
        var moved = matrix_identity_float4x4
        moved.columns.3 = SIMD4<Float>(2, 0, 0, 1)
        var emitter = ParticleEmitter(emissionRate: 0,
                                      distanceEmissionRate: 1,
                                      maxParticles: 8,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      velocityInheritance: 0.5,
                                      gravity: .zero,
                                      simulationSpace: .world)

        emitter.advance(deltaTime: 1, worldTransform: start)
        emitter.advance(deltaTime: 1, worldTransform: moved)

        #expect(emitter.aliveCount == 2)
        #expect(emitter.particles.allSatisfy { $0.velocity == SIMD3<Float>(1, 0, 0) })
    }

    @Test("non-looping duration stops new emissions")
    func nonLoopingDurationStopsEmission() {
        var emitter = ParticleEmitter(looping: false, duration: 0.5,
                                      emissionRate: 10, maxParticles: 100, lifetime: 100,
                                      startVelocity: .zero, gravity: .zero)
        emitter.advance(deltaTime: 0.5)
        #expect(emitter.aliveCount == 5)
        emitter.advance(deltaTime: 1.0)
        #expect(emitter.aliveCount == 5)

        emitter.clear()
        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 1)
    }

    @Test("particles are culled once they exceed their lifetime")
    func lifetimeCulling() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 0.5, gravity: .zero)
        emitter.emit(3)
        #expect(emitter.aliveCount == 3)
        emitter.advance(deltaTime: 0.6) // age 0.6 > lifetime 0.5
        #expect(emitter.aliveCount == 0)
    }

    @Test("death sub-emitter spawns child particles with independent appearance")
    func deathSubEmitter() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 0.5,
                                      subEmitterTrigger: .death,
                                      subEmitterBurstCount: 2,
                                      subEmitterMaxDepth: 1,
                                      subEmitterLifetime: 2,
                                      subEmitterStartVelocity: SIMD3<Float>(1, 0, 0),
                                      subEmitterVelocityRandomness: .zero,
                                      subEmitterStartSize: 0.25,
                                      subEmitterEndSize: 0.25,
                                      subEmitterStartColor: SIMD4<Float>(1, 0, 0, 1),
                                      subEmitterEndColor: SIMD4<Float>(1, 0, 0, 1),
                                      startVelocity: .zero,
                                      gravity: .zero)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.6)

        #expect(emitter.aliveCount == 2)
        #expect(emitter.lastFrameEvents.count == 1)
        #expect(emitter.lastFrameEvents[0].trigger == .death)
        #expect(emitter.lastFrameEvents[0].generation == 0)
        #expect(emitter.lastFrameEvents[0].age >= 0.6)
        #expect(emitter.lastFrameEvents[0].lifetime == 0.5)
        for child in emitter.particles {
            #expect(child.generation == 1)
            #expect(child.lifetime == 2)
            #expect(child.velocity == SIMD3<Float>(1, 0, 0))
            #expect(child.size == 0.25)
            #expect(child.color == SIMD4<Float>(1, 0, 0, 1))
        }

        emitter.advance(deltaTime: 2.1)
        #expect(emitter.aliveCount == 0)
        #expect(emitter.lastFrameEvents.count == 2)

        emitter.clear()
        #expect(emitter.lastFrameEvents.isEmpty)
    }

    @Test("multiple death sub-emitter rules spawn independent child appearances")
    func multipleDeathSubEmitters() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 0.5,
                                      subEmitters: [
                                          ParticleSubEmitter(trigger: .death,
                                                             burstCount: 1,
                                                             lifetime: 2,
                                                             startVelocity: SIMD3<Float>(1, 0, 0),
                                                             startSize: 0.2,
                                                             endSize: 0.2,
                                                             startColor: SIMD4<Float>(1, 0, 0, 1),
                                                             endColor: SIMD4<Float>(1, 0, 0, 1)),
                                          ParticleSubEmitter(trigger: .death,
                                                             burstCount: 2,
                                                             lifetime: 3,
                                                             startVelocity: SIMD3<Float>(0, 1, 0),
                                                             startSize: 0.4,
                                                             endSize: 0.4,
                                                             startColor: SIMD4<Float>(0, 0, 1, 1),
                                                             endColor: SIMD4<Float>(0, 0, 1, 1)),
                                      ],
                                      startVelocity: .zero,
                                      gravity: .zero)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.6)

        #expect(emitter.aliveCount == 3)
        let redChildren = emitter.particles.filter { $0.appearanceIndex == 2 }
        let blueChildren = emitter.particles.filter { $0.appearanceIndex == 3 }
        #expect(redChildren.count == 1)
        #expect(blueChildren.count == 2)
        #expect(redChildren.allSatisfy { $0.generation == 1 && $0.lifetime == 2 })
        #expect(redChildren.allSatisfy { $0.velocity == SIMD3<Float>(1, 0, 0) })
        #expect(redChildren.allSatisfy { $0.size == 0.2 && $0.color == SIMD4<Float>(1, 0, 0, 1) })
        #expect(blueChildren.allSatisfy { $0.generation == 1 && $0.lifetime == 3 })
        #expect(blueChildren.allSatisfy { $0.velocity == SIMD3<Float>(0, 1, 0) })
        #expect(blueChildren.allSatisfy { $0.size == 0.4 && $0.color == SIMD4<Float>(0, 0, 1, 1) })
    }

    @Test("collision sub-emitter spawns child particles at the collision point")
    func collisionSubEmitter() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 10,
                                      subEmitterTrigger: .collision,
                                      subEmitterBurstCount: 1,
                                      subEmitterLifetime: 2,
                                      subEmitterStartVelocity: SIMD3<Float>(2, 0, 0),
                                      subEmitterVelocityRandomness: .zero,
                                      originOffset: SIMD3<Float>(0, 0.5, 0),
                                      startVelocity: SIMD3<Float>(0, -1, 0),
                                      gravity: .zero,
                                      collisionMode: .localPlane,
                                      collisionPlaneY: 0,
                                      collisionRestitution: 0.5)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        #expect(emitter.aliveCount == 2)
        let parent = emitter.particles.first { $0.generation == 0 }
        let child = emitter.particles.first { $0.generation == 1 }
        #expect(parent != nil)
        #expect(child != nil)
        #expect(parent!.position.y == 0)
        #expect(abs(parent!.velocity.y - 0.5) < 1e-4)
        #expect(child!.position.y == 0)
        #expect(child!.velocity == SIMD3<Float>(2, 0, 0))
        #expect(emitter.lastFrameEvents.count == 1)
        #expect(emitter.lastFrameEvents[0].trigger == .collision)
        #expect(emitter.lastFrameEvents[0].position.y == 0)
        #expect(abs(emitter.lastFrameEvents[0].velocity.y - 0.5) < 1e-4)
    }

    @Test("external simulation events drive sub-emitter spawning")
    func externalSimulationEventsDriveSubEmitters() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 10,
                                      subEmitters: [
                                          ParticleSubEmitter(trigger: .death,
                                                             burstCount: 2,
                                                             maxDepth: 2,
                                                             inheritVelocity: 0.5,
                                                             lifetime: 3,
                                                             startVelocity: SIMD3<Float>(1, 0, 0),
                                                             velocityRandomness: .zero,
                                                             startSize: 0.3,
                                                             endSize: 0.1,
                                                             startColor: SIMD4<Float>(1, 0, 0, 1),
                                                             endColor: SIMD4<Float>(1, 1, 0, 0.5)),
                                      ],
                                      startVelocity: .zero,
                                      gravity: .zero)
        let sourceEvent = ParticleEvent(trigger: .death,
                                        position: SIMD3<Float>(2, 3, 4),
                                        velocity: SIMD3<Float>(0, 2, 0),
                                        age: 0.75,
                                        lifetime: 1.5,
                                        generation: 0,
                                        appearanceIndex: 0)

        let stats = emitter.applySimulationEvents([sourceEvent])

        #expect(stats.expiredParticleCount == 1)
        #expect(stats.subEmitterSpawnedCount == 2)
        #expect(stats.spawnedParticleCount == 2)
        #expect(stats.liveParticleCount == 2)
        #expect(emitter.lastFrameEvents == [sourceEvent])
        #expect(emitter.lastFrameSpawnedParticles.count == 2)
        #expect(emitter.particles.count == 2)
        for child in emitter.particles {
            #expect(child.position == SIMD3<Float>(2, 3, 4))
            #expect(child.velocity == SIMD3<Float>(1, 1, 0))
            #expect(child.generation == 1)
            #expect(child.appearanceIndex == 2)
            #expect(child.lifetime == 3)
            #expect(child.size == 0.3)
            #expect(child.color == SIMD4<Float>(1, 0, 0, 1))
        }
    }

    @Test("external simulation event bridge clears stale frame output")
    func externalSimulationEventBridgeClearsStaleOutput() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 4,
                                      subEmitterTrigger: .collision,
                                      subEmitterBurstCount: 1,
                                      subEmitterLifetime: 1,
                                      subEmitterStartVelocity: SIMD3<Float>(0, 1, 0),
                                      subEmitterVelocityRandomness: .zero,
                                      startVelocity: .zero,
                                      gravity: .zero)
        let sourceEvent = ParticleEvent(trigger: .collision,
                                        position: .zero,
                                        velocity: .zero,
                                        age: 0,
                                        lifetime: 1,
                                        generation: 0,
                                        appearanceIndex: 0)

        _ = emitter.applySimulationEvents([sourceEvent])
        #expect(emitter.lastFrameEvents.count == 1)
        #expect(emitter.lastFrameSpawnedParticles.count == 1)

        let emptyStats = emitter.applySimulationEvents([])

        #expect(emptyStats.spawnedParticleCount == 0)
        #expect(emptyStats.liveParticleCount == 1)
        #expect(emitter.lastFrameEvents.isEmpty)
        #expect(emitter.lastFrameSpawnedParticles.isEmpty)
    }

    @Test("GPU event sub-emitters defer CPU spawning until external simulation feedback")
    func gpuEventSubEmittersDeferToExternalSimulationEvents() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 8,
                                      lifetime: 0.5,
                                      subEmitterTrigger: .death,
                                      subEmitterBurstCount: 2,
                                      subEmitterMaxDepth: 1,
                                      subEmitterLifetime: 2,
                                      subEmitterStartVelocity: SIMD3<Float>(1, 0, 0),
                                      subEmitterVelocityRandomness: .zero,
                                      gravity: .zero,
                                      simulationBackend: .gpuIfSupported)
        #expect(emitter.gpuSimulationPlan.usesGPU)

        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        #expect(emitter.aliveCount == 0)
        #expect(emitter.lastFrameStats.expiredParticleCount == 1)
        #expect(emitter.lastFrameStats.subEmitterSpawnedCount == 0)
        #expect(emitter.lastFrameEvents.isEmpty)
        #expect(emitter.lastFrameSpawnedParticles.isEmpty)

        let feedback = ParticleEvent(trigger: .death,
                                     position: SIMD3<Float>(2, 0, 0),
                                     velocity: .zero,
                                     age: 0.5,
                                     lifetime: 0.5,
                                     generation: 0,
                                     appearanceIndex: 0)
        let feedbackStats = emitter.applySimulationEvents([feedback])

        #expect(feedbackStats.expiredParticleCount == 1)
        #expect(feedbackStats.subEmitterSpawnedCount == 2)
        #expect(emitter.aliveCount == 2)
        #expect(emitter.lastFrameEvents == [feedback])
        #expect(emitter.lastFrameSpawnedParticles.count == 2)
    }

    @Test("GPU fallback keeps CPU-owned event sub-emitter spawning")
    func gpuFallbackKeepsCPUOwnedEventSubEmitterSpawning() {
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      distanceEmissionRate: 1,
                                      maxParticles: 4,
                                      lifetime: 0.5,
                                      subEmitterTrigger: .death,
                                      subEmitterBurstCount: 1,
                                      subEmitterMaxDepth: 1,
                                      subEmitterLifetime: 2,
                                      subEmitterStartVelocity: .zero,
                                      subEmitterVelocityRandomness: .zero,
                                      gravity: .zero,
                                      simulationBackend: .gpuIfSupported)
        #expect(emitter.gpuSimulationPlan.status == .fallbackToCPU)
        #expect(!emitter.gpuSimulationPlan.usesGPU)

        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        #expect(emitter.aliveCount == 1)
        #expect(emitter.lastFrameStats.expiredParticleCount == 1)
        #expect(emitter.lastFrameStats.subEmitterSpawnedCount == 1)
        #expect(emitter.lastFrameEvents.count == 1)
        #expect(emitter.lastFrameSpawnedParticles.count == 1)
    }

    @Test("SceneRuntime applies external particle simulation events by entity")
    func sceneRuntimeAppliesExternalParticleSimulationEventsByEntity() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            ParticleEmitter(isEmitting: false,
                            emissionRate: 0,
                            maxParticles: 1,
                            subEmitterTrigger: .death,
                            subEmitterBurstCount: 2,
                            subEmitterLifetime: 2,
                            subEmitterStartVelocity: .zero,
                            subEmitterVelocityRandomness: .zero,
                            gravity: .zero),
            for: entity
        )
        let empty = scene.createEntity()
        let missing = EntityID(index: 99, generation: 1)
        let event = ParticleEvent(trigger: .death,
                                  position: SIMD3<Float>(1, 2, 3),
                                  velocity: .zero,
                                  age: 1,
                                  lifetime: 1,
                                  generation: 0,
                                  appearanceIndex: 0)
        let collision = ParticleEvent(trigger: .collision,
                                      position: SIMD3<Float>(4, 5, 6),
                                      velocity: SIMD3<Float>(0, 1, 0),
                                      age: 0.25,
                                      lifetime: 1,
                                      generation: 0,
                                      appearanceIndex: 0)

        let report = scene.applyParticleSimulationEvents([
            entity: [event, collision],
            empty: [],
            missing: [event],
        ])

        #expect(report.requestedEmitterCount == 3)
        #expect(report.appliedEmitterCount == 1)
        #expect(report.missingEmitterCount == 1)
        #expect(report.emptyEventEmitterCount == 1)
        #expect(report.eventCount == 3)
        #expect(report.appliedEventCount == 2)
        #expect(report.deathEventCount == 1)
        #expect(report.collisionEventCount == 1)
        #expect(report.subEmitterSpawnedCount == 1)
        #expect(report.spawnedParticleCount == 1)
        #expect(report.capacityLimitedSpawnCount == 1)
        let emitter = scene.component(ParticleEmitter.self, for: entity)
        #expect(emitter?.particles.count == 1)
        #expect(emitter?.lastFrameEvents == [event, collision])
        #expect(scene.particleFrameStats.subEmitterSpawnedCount == 1)
        #expect(scene.particleFrameStats.capacityLimitedSpawnCount == 1)
        #expect(report.emitterStats(for: entity.rawValue)?.subEmitterSpawnedCount == 1)
        #expect(report.emitterStats(for: entity.rawValue)?.capacityLimitedSpawnCount == 1)
        #expect(scene.particleFrameStats.emitterStats(for: entity.rawValue)?.subEmitterSpawnedCount == 1)
        #expect(scene.particleFrameStats.emitterStats(for: missing.rawValue) == nil)
    }

    @Test("gravity and velocity integrate with semi-implicit Euler")
    func motionIntegration() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 100,
                                      spawnRadius: 0, startVelocity: .zero,
                                      gravity: SIMD3<Float>(0, -10, 0))
        emitter.emit(1)
        emitter.advance(deltaTime: 1)
        let p = emitter.particles[0]
        #expect(abs(p.velocity.y + 10) < 1e-4)   // v += g*dt → -10
        #expect(abs(p.position.y + 10) < 1e-4)   // p += v*dt → -10
    }

    @Test("radial force accelerates particles away from the force center")
    func radialForce() {
        var emitter = ParticleEmitter(emissionRate: 0,
                                      lifetime: 10,
                                      originOffset: SIMD3<Float>(1, 0, 0),
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      forceMode: .radial,
                                      forceRadius: 0,
                                      forceStrength: 2,
                                      forceFalloff: 0)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        #expect(abs(p.velocity.x - 2) < 1e-4)
        #expect(abs(p.position.x - 3) < 1e-4)
    }

    @Test("vortex force accelerates particles around the configured axis")
    func vortexForce() {
        var emitter = ParticleEmitter(emissionRate: 0,
                                      lifetime: 10,
                                      originOffset: SIMD3<Float>(1, 0, 0),
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      forceMode: .vortex,
                                      forceAxis: SIMD3<Float>(0, 1, 0),
                                      forceRadius: 0,
                                      forceStrength: 3,
                                      forceFalloff: 0)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        #expect(abs(p.velocity.z + 3) < 1e-4)
        #expect(abs(p.position.z + 3) < 1e-4)
    }

    @Test("uniform vector field accelerates particles in the configured direction")
    func uniformVectorField() {
        var emitter = ParticleEmitter(emissionRate: 0,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      vectorFieldMode: .uniform,
                                      vectorFieldDirection: SIMD3<Float>(2, 0, 0),
                                      vectorFieldStrength: 4)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.5)

        let p = emitter.particles[0]
        #expect(abs(p.velocity.x - 2) < 1e-4)
        #expect(abs(p.position.x - 1) < 1e-4)
        #expect(abs(p.velocity.y) < 1e-4)
        #expect(abs(p.position.y) < 1e-4)
    }

    @Test("GPU simulation plan reports dispatch shape and unsupported module fallbacks")
    func gpuSimulationPlan() {
        let supported = ParticleEmitter(emissionRate: 10,
                                        maxParticles: 130,
                                        lifetime: 10,
                                        simulationBackend: .gpuIfSupported,
                                        gpuSimulationWorkgroupSize: 64)
        let supportedPlan = supported.gpuSimulationPlan
        #expect(supportedPlan.status == .supported)
        #expect(supportedPlan.usesGPU)
        #expect(supportedPlan.particleCapacity == 130)
        #expect(supportedPlan.workgroupSize == 64)
        #expect(supportedPlan.dispatchWorkgroups == 3)
        #expect(supportedPlan.unsupportedReasons.isEmpty)

        let clamped = ParticleEmitter(emissionRate: 10,
                                      maxParticles: 513,
                                      lifetime: 10,
                                      simulationBackend: .gpuIfSupported,
                                      gpuSimulationWorkgroupSize: 512)
        let clampedPlan = clamped.gpuSimulationPlan
        #expect(clampedPlan.status == .supported)
        #expect(clampedPlan.workgroupSize == ParticleGPUSimulationPlan.maximumWorkgroupSize)
        #expect(clampedPlan.dispatchWorkgroups == 3)

        let fallback = ParticleEmitter(emissionRate: 0,
                                       distanceEmissionRate: 2,
                                       maxParticles: 64,
                                       lifetime: 10,
                                       simulationBackend: .gpuIfSupported)
        let fallbackPlan = fallback.gpuSimulationPlan
        #expect(fallbackPlan.status == .fallbackToCPU)
        #expect(!fallbackPlan.usesGPU)
        #expect(fallbackPlan.unsupportedReasons == [.distanceEmission])

        let complexFallback = ParticleEmitter(emissionRate: 10,
                                              maxParticles: 64,
                                              lifetime: 10,
                                              noiseStrength: 1,
                                              forceMode: .radial,
                                              forceStrength: 2,
                                              vectorFieldMode: .uniform,
                                              vectorFieldStrength: 3,
                                              collisionMode: .localPlane,
                                              simulationBackend: .gpuIfSupported,
                                              angularVelocity: 0.25)
        let complexFallbackPlan = complexFallback.gpuSimulationPlan
        #expect(complexFallbackPlan.status == .supported)
        #expect(complexFallbackPlan.usesGPU)
        #expect(complexFallbackPlan.unsupportedReasons.isEmpty)

        let noisePlan = ParticleEmitter(emissionRate: 10,
                                        maxParticles: 64,
                                        lifetime: 10,
                                        noiseStrength: 2,
                                        noiseScale: 3,
                                        noiseSpeed: 0.5,
                                        simulationBackend: .gpuIfSupported).gpuSimulationPlan
        #expect(noisePlan.status == .supported)
        #expect(noisePlan.usesGPU)

        let forcePlan = ParticleEmitter(emissionRate: 10,
                                        maxParticles: 64,
                                        lifetime: 10,
                                        forceMode: .vortex,
                                        forceAxis: SIMD3<Float>(0, 1, 0),
                                        forceRadius: 8,
                                        forceStrength: -3,
                                        forceFalloff: 2,
                                        simulationBackend: .gpuIfSupported).gpuSimulationPlan
        #expect(forcePlan.status == .supported)
        #expect(forcePlan.usesGPU)

        let uniformVectorFieldPlan = ParticleEmitter(emissionRate: 10,
                                                     maxParticles: 64,
                                                     lifetime: 10,
                                                     vectorFieldMode: .uniform,
                                                     vectorFieldDirection: SIMD3<Float>(2, 0, 0),
                                                     vectorFieldStrength: 4,
                                                     simulationBackend: .gpuIfSupported).gpuSimulationPlan
        #expect(uniformVectorFieldPlan.status == .supported)
        #expect(uniformVectorFieldPlan.usesGPU)

        let angularVelocityPlan = ParticleEmitter(emissionRate: 10,
                                                  maxParticles: 64,
                                                  lifetime: 10,
                                                  simulationBackend: .gpuIfSupported,
                                                  angularVelocity: 0.25,
                                                  angularVelocityRandomness: 0.1).gpuSimulationPlan
        #expect(angularVelocityPlan.status == .supported)
        #expect(angularVelocityPlan.usesGPU)

        let planeCollisionPlan = ParticleEmitter(emissionRate: 10,
                                                 maxParticles: 64,
                                                 lifetime: 10,
                                                 collisionMode: .worldPlane,
                                                 simulationBackend: .gpuIfSupported,
                                                 collisionPlaneY: -1,
                                                 collisionRestitution: 0.25,
                                                 collisionDamping: 0.5).gpuSimulationPlan
        #expect(planeCollisionPlan.status == .supported)
        #expect(planeCollisionPlan.usesGPU)

        let required = ParticleEmitter(emissionRate: 10,
                                       maxParticles: 64,
                                       lifetime: 10,
                                       subEmitterTrigger: .death,
                                       subEmitterBurstCount: 1,
                                       simulationBackend: .gpuRequired)
        let requiredPlan = required.gpuSimulationPlan
        #expect(requiredPlan.status == .supported)
        #expect(requiredPlan.usesGPU)
        #expect(requiredPlan.unsupportedReasons.isEmpty)

        let collisionEventRequired = ParticleEmitter(emissionRate: 10,
                                                     maxParticles: 64,
                                                     lifetime: 10,
                                                     subEmitterTrigger: .collision,
                                                     subEmitterBurstCount: 1,
                                                     collisionMode: .worldPlane,
                                                     simulationBackend: .gpuRequired).gpuSimulationPlan
        #expect(collisionEventRequired.status == .supported)
        #expect(collisionEventRequired.usesGPU)
        #expect(collisionEventRequired.unsupportedReasons.isEmpty)
    }

    @Test("maxParticles caps the live pool")
    func maxParticlesCap() {
        var emitter = ParticleEmitter(emissionRate: 10_000, maxParticles: 5, lifetime: 1000, gravity: .zero)
        for _ in 0..<10 { emitter.advance(deltaTime: 0.1) }
        #expect(emitter.aliveCount == 5)
        emitter.emit(100)
        #expect(emitter.aliveCount == 5)
    }

    @Test("identical seeds produce identical simulations")
    func deterministicWithSeed() {
        func run() -> [Particle] {
            var e = ParticleEmitter(emissionRate: 50, maxParticles: 64, lifetime: 5,
                                    spawnRadius: 1,
                                    velocityRandomness: SIMD3<Float>(2, 2, 2),
                                    gravity: SIMD3<Float>(0, -9.81, 0), seed: 42)
            for _ in 0..<20 { e.advance(deltaTime: 1.0 / 60.0) }
            return e.particles
        }
        #expect(run() == run())
    }

    @Test("box emission spawns within configured half extents")
    func boxEmissionShape() {
        var emitter = ParticleEmitter(emissionRate: 0, maxParticles: 64, lifetime: 10,
                                      emissionShape: .box,
                                      boxHalfExtents: SIMD3<Float>(2, 3, 4),
                                      startVelocity: .zero, gravity: .zero,
                                      seed: 7)
        emitter.emit(32)

        #expect(emitter.aliveCount == 32)
        for p in emitter.particles {
            #expect(abs(p.position.x) <= 2)
            #expect(abs(p.position.y) <= 3)
            #expect(abs(p.position.z) <= 4)
        }
    }

    @Test("cone emission spawns inside cone volume oriented by start velocity")
    func coneEmissionShape() {
        var emitter = ParticleEmitter(emissionRate: 0, maxParticles: 64, lifetime: 10,
                                      emissionShape: .cone,
                                      coneRadius: 2, coneHeight: 5,
                                      startVelocity: SIMD3<Float>(0, 1, 0),
                                      gravity: .zero, seed: 11)
        emitter.emit(32)

        #expect(emitter.aliveCount == 32)
        for p in emitter.particles {
            #expect(p.position.y >= 0)
            #expect(p.position.y <= 5)
            let radial = sqrt(p.position.x * p.position.x + p.position.z * p.position.z)
            let allowedRadius = 2 * (p.position.y / 5)
            #expect(radial <= allowedRadius + 0.0001)
        }
    }

    @Test("local plane collision bounces particles and damps tangent velocity")
    func localPlaneCollision() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 100,
                                      startVelocity: SIMD3<Float>(4, 0, 0),
                                      gravity: SIMD3<Float>(0, -10, 0),
                                      collisionMode: .localPlane,
                                      collisionPlaneY: 0,
                                      collisionRestitution: 0.5,
                                      collisionDamping: 0.25)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        #expect(abs(p.position.y) < 1e-4)
        #expect(abs(p.velocity.y - 5) < 1e-4)
        #expect(abs(p.velocity.x - 3) < 1e-4)
    }

    @Test("world plane collision uses the entity world transform")
    func worldPlaneCollision() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var worldMatrix = matrix_identity_float4x4
        worldMatrix.columns.3 = SIMD4<Float>(0, 5, 0, 1)
        _ = scene.setComponent(WorldTransform(matrix: worldMatrix), for: entity)

        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 100,
                                      startVelocity: SIMD3<Float>(4, 0, 0),
                                      gravity: SIMD3<Float>(0, -10, 0),
                                      collisionMode: .worldPlane,
                                      collisionPlaneY: 0,
                                      collisionRestitution: 0.5,
                                      collisionDamping: 0.25)
        emitter.emit(1)
        _ = scene.setComponent(emitter, for: entity)

        #expect(scene.advanceParticles(deltaTime: 1) == 1)

        let p = scene.component(ParticleEmitter.self, for: entity)!.particles[0]
        #expect(abs(p.position.y + 5) < 1e-4)
        #expect(abs(p.velocity.y - 5) < 1e-4)
        #expect(abs(p.velocity.x - 3) < 1e-4)
    }

    @Test("isEmitting=false stops new spawns but still ages live particles")
    func stoppedEmitterStillAges() {
        var emitter = ParticleEmitter(emissionRate: 100, lifetime: 0.5, gravity: .zero)
        emitter.emit(4)
        emitter.isEmitting = false
        #expect(emitter.aliveCount == 4)
        emitter.advance(deltaTime: 0.6)
        #expect(emitter.aliveCount == 0) // aged out, none replaced
    }

    @Test("appearance lerps from start to end across lifetime")
    func appearanceGradient() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 1, gravity: .zero,
                                      startSize: 2, endSize: 0,
                                      startColor: SIMD4<Float>(1, 1, 1, 1),
                                      endColor: SIMD4<Float>(1, 1, 1, 0))
        emitter.emit(1)
        emitter.advance(deltaTime: 0.5) // halfway through life
        let p = emitter.particles[0]
        #expect(abs(p.size - 1) < 1e-4)        // lerp(2, 0, 0.5) = 1
        #expect(abs(p.color.w - 0.5) < 1e-4)   // alpha lerp(1, 0, 0.5) = 0.5
    }

    @Test("appearance curves remap normalized age for size and color")
    func appearanceCurves() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 1, gravity: .zero,
                                      startSize: 0, endSize: 1, sizeCurve: .easeIn,
                                      startColor: SIMD4<Float>(1, 1, 1, 0),
                                      endColor: SIMD4<Float>(1, 1, 1, 1),
                                      colorCurve: .easeOut)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.5)

        let p = emitter.particles[0]
        #expect(abs(p.size - 0.25) < 1e-4)
        #expect(abs(p.color.w - 0.75) < 1e-4)
    }

    @Test("size randomness applies stable per-particle scales")
    func sizeRandomness() {
        func run() -> [Particle] {
            var emitter = ParticleEmitter(emissionRate: 0,
                                          maxParticles: 8,
                                          lifetime: 1,
                                          gravity: .zero,
                                          startSize: 2,
                                          endSize: 2,
                                          sizeRandomness: 0.5,
                                          seed: 99)
            emitter.emit(4)
            emitter.advance(deltaTime: 0.25)
            return emitter.particles
        }

        let particles = run()
        #expect(particles == run())
        #expect(particles.allSatisfy { $0.size >= 1 && $0.size <= 3 })
        #expect(particles.contains { abs($0.size - 2) > 0.0001 })
    }

    @Test("particle rotation integrates angular velocity")
    func particleRotation() {
        var emitter = ParticleEmitter(emissionRate: 0,
                                      maxParticles: 4,
                                      lifetime: 10,
                                      startVelocity: .zero,
                                      gravity: .zero,
                                      startRotation: 0.25,
                                      angularVelocity: 2)
        emitter.emit(1)
        emitter.advance(deltaTime: 0.5)

        let p = emitter.particles[0]
        #expect(abs(p.rotation - 1.25) < 1e-4)
        #expect(abs(p.angularVelocity - 2) < 1e-4)
    }

    @Test("world simulation space spawns and stores particles in world coordinates")
    func worldSimulationSpaceStoresWorldParticles() {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(10, 0, 0, 1)
        var emitter = ParticleEmitter(isEmitting: false,
                                      emissionRate: 0,
                                      maxParticles: 4,
                                      lifetime: 10,
                                      originOffset: SIMD3<Float>(1, 0, 0),
                                      startVelocity: SIMD3<Float>(0, 2, 0),
                                      gravity: .zero,
                                      simulationSpace: .world)
        emitter.emit(1, worldTransform: transform)

        #expect(emitter.particles.count == 1)
        #expect(emitter.particles[0].position == SIMD3<Float>(11, 0, 0))
        #expect(emitter.particles[0].velocity == SIMD3<Float>(0, 2, 0))
        emitter.advance(deltaTime: 0.5, worldTransform: matrix_identity_float4x4)
        #expect(emitter.particles[0].position == SIMD3<Float>(11, 1, 0))
    }

    @Test("SceneRuntime.emitParticles passes entity transform for world-space emitters")
    func sceneEmitParticlesUsesWorldTransformForWorldSpaceEmitters() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 0, 0)), for: entity)
        scene.propagateTransforms()
        _ = scene.setComponent(
            ParticleEmitter(isEmitting: false,
                            emissionRate: 0,
                            maxParticles: 2,
                            lifetime: 10,
                            startVelocity: .zero,
                            gravity: .zero,
                            simulationSpace: .world),
            for: entity
        )

        let emitted = scene.emitParticles(from: entity, count: 1)
        #expect(emitted)
        #expect(scene.component(ParticleEmitter.self, for: entity)?.particles[0].position == SIMD3<Float>(4, 0, 0))
    }

    @Test("keyframe curves linearly interpolate sorted keys")
    func appearanceKeyframeCurves() {
        var emitter = ParticleEmitter(
            emissionRate: 0,
            lifetime: 1,
            gravity: .zero,
            startSize: 0,
            endSize: 10,
            sizeCurve: .keyframes([
                ParticleCurveKeyframe(time: 1, value: 0),
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 0.5, value: 1),
            ]),
            startColor: SIMD4<Float>(1, 1, 1, 0),
            endColor: SIMD4<Float>(1, 1, 1, 1),
            colorCurve: .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 0.5),
            ])
        )
        emitter.emit(1)
        emitter.advance(deltaTime: 0.25)

        let p = emitter.particles[0]
        #expect(abs(p.size - 5) < 1e-4)
        #expect(abs(p.color.w - 0.125) < 1e-4)
    }

    @Test("ParticleCurve evaluates presets and keyframes")
    func particleCurveEvaluation() {
        #expect(ParticleCurve.constant(2.5).evaluate(at: -1) == 2.5)
        #expect(ParticleCurve.constant(2.5).evaluate(at: 2) == 2.5)
        #expect(ParticleCurve.linear.evaluate(at: -1) == 0)
        #expect(ParticleCurve.linear.evaluate(at: 2) == 1)
        #expect(abs(ParticleCurve.easeIn.evaluate(at: 0.5) - 0.25) < 1e-4)
        #expect(abs(ParticleCurve.easeOut.evaluate(at: 0.5) - 0.75) < 1e-4)
        #expect(abs(ParticleCurve.easeInOut.evaluate(at: 0.25) - 0.125) < 1e-4)

        let curve = ParticleCurve.keyframes([
            ParticleCurveKeyframe(time: 1, value: 0),
            ParticleCurveKeyframe(time: 0, value: 0),
            ParticleCurveKeyframe(time: 0.5, value: 1),
        ])
        #expect(abs(curve.evaluate(at: 0.25) - 0.5) < 1e-4)
        #expect(abs(curve.evaluate(at: 0.75) - 0.5) < 1e-4)
    }

    @Test("emission rate curve modulates continuous spawn rate over emitter duration")
    func emissionRateCurveModulatesContinuousEmission() {
        var emitter = ParticleEmitter(
            looping: false,
            duration: 2,
            emissionRate: 10,
            emissionRateCurve: .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ]),
            maxParticles: 100,
            lifetime: 10,
            startVelocity: .zero,
            gravity: .zero
        )

        emitter.advance(deltaTime: 1)
        #expect(emitter.aliveCount == 5)
        emitter.advance(deltaTime: 1)
        #expect(emitter.aliveCount == 20)
    }

    @Test("distance emission rate curve modulates movement-based spawn rate")
    func distanceEmissionRateCurveModulatesDistanceEmission() {
        var emitter = ParticleEmitter(
            looping: false,
            duration: 2,
            emissionRate: 0,
            distanceEmissionRate: 10,
            distanceEmissionRateCurve: .keyframes([
                ParticleCurveKeyframe(time: 0, value: 0),
                ParticleCurveKeyframe(time: 1, value: 2),
            ]),
            maxParticles: 100,
            lifetime: 10,
            startVelocity: .zero,
            gravity: .zero,
            simulationSpace: .world
        )
        var transform = matrix_identity_float4x4

        emitter.advance(deltaTime: 0.01, worldTransform: transform)
        transform.columns.3.x = 1
        emitter.advance(deltaTime: 1, worldTransform: transform)
        #expect(emitter.aliveCount == 5)
        transform.columns.3.x = 2
        emitter.advance(deltaTime: 1, worldTransform: transform)
        #expect(emitter.aliveCount == 20)
    }

    @Test("prewarm simulates once before the first active tick")
    func prewarmSimulatesBeforeFirstTick() {
        var emitter = ParticleEmitter(
            prewarmTime: 1,
            prewarmStep: 0.5,
            emissionRate: 10,
            maxParticles: 100,
            lifetime: 10,
            startVelocity: .zero,
            gravity: .zero
        )

        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 11)
        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 12)

        emitter.clear()
        emitter.advance(deltaTime: 0.1)
        #expect(emitter.aliveCount == 11)
    }

    @Test("texture sheet UV rect advances over lifetime or frame rate")
    func textureSheetUVRect() {
        var lifetimeEmitter = ParticleEmitter(emissionRate: 0,
                                              lifetime: 1,
                                              gravity: .zero,
                                              textureSheetColumns: 2,
                                              textureSheetRows: 2,
                                              textureSheetFrameCount: 4)
        lifetimeEmitter.emit(1)
        lifetimeEmitter.advance(deltaTime: 0.5)
        #expect(lifetimeEmitter.textureUVRect(for: lifetimeEmitter.particles[0]) == SIMD4<Float>(0, 0.5, 0.5, 0.5))

        var rateEmitter = ParticleEmitter(emissionRate: 0,
                                          lifetime: 10,
                                          gravity: .zero,
                                          textureSheetColumns: 4,
                                          textureSheetRows: 1,
                                          textureSheetFrameCount: 4,
                                          textureSheetFrameRate: 2)
        rateEmitter.emit(1)
        rateEmitter.advance(deltaTime: 1.5)
        #expect(rateEmitter.textureUVRect(for: rateEmitter.particles[0]) == SIMD4<Float>(0.75, 0, 0.25, 1))
    }

    @Test("texture sheet playback supports ranges, loops, and stable random start frames")
    func textureSheetPlaybackModes() {
        let particle = Particle(position: .zero,
                                velocity: .zero,
                                age: 2,
                                lifetime: 10,
                                textureFrameSeed: 5)

        let playOnce = ParticleEmitter(textureSheetColumns: 4,
                                       textureSheetRows: 2,
                                       textureSheetFrameCount: 3,
                                       textureSheetFrameRate: 2,
                                       textureSheetPlaybackMode: .playOnce,
                                       textureSheetStartFrame: 2)
        #expect(playOnce.textureSheetFrameIndex(for: particle) == 4)
        #expect(playOnce.textureUVRect(for: particle) == SIMD4<Float>(0, 0.5, 0.25, 0.5))

        let loop = ParticleEmitter(textureSheetColumns: 4,
                                   textureSheetRows: 2,
                                   textureSheetFrameCount: 3,
                                   textureSheetFrameRate: 2,
                                   textureSheetPlaybackMode: .loop,
                                   textureSheetStartFrame: 2)
        #expect(loop.textureSheetFrameIndex(for: particle) == 3)
        #expect(loop.textureUVRect(for: particle) == SIMD4<Float>(0.75, 0, 0.25, 0.5))

        let randomSingleFrame = ParticleEmitter(textureSheetColumns: 4,
                                                textureSheetRows: 2,
                                                textureSheetFrameCount: 3,
                                                textureSheetPlaybackMode: .singleFrame,
                                                textureSheetStartFrame: 2,
                                                textureSheetFrameRandomness: 2)
        #expect(randomSingleFrame.textureSheetFrameIndex(for: particle) == 4)
    }

    @Test("trail configuration is sanitized at construction")
    func trailConfigurationSanitizes() {
        let emitter = ParticleEmitter(ribbonWidthScale: -1,
                                      ribbonTailWidthScale: -0.5,
                                      ribbonTailAlphaScale: 2,
                                      ribbonMaxSegmentLength: -4,
                                      ribbonJoinOverlapScale: -1,
                                      ribbonSmoothingSegments: -2,
                                      ribbonTextureTiling: -2,
                                      ribbonTextureOffset: -0.25,
                                      trailLength: -1,
                                      trailSegments: -4,
                                      trailEndSizeScale: -0.5,
                                      trailEndAlphaScale: 2)

        #expect(emitter.trailLength == 0)
        #expect(emitter.trailSegments == 0)
        #expect(emitter.trailEndSizeScale == 0)
        #expect(emitter.trailEndAlphaScale == 1)
        #expect(emitter.ribbonWidthScale == 0)
        #expect(emitter.ribbonTailWidthScale == 0)
        #expect(emitter.ribbonTailAlphaScale == 1)
        #expect(emitter.ribbonMaxSegmentLength == 0)
        #expect(emitter.ribbonJoinOverlapScale == 0)
        #expect(emitter.ribbonSmoothingSegments == 1)
        #expect(emitter.ribbonTextureTiling == 0)
        #expect(emitter.ribbonTextureOffset == -0.25)
    }

    @Test("automatic render bounds estimate covers configured motion and billboard size")
    func automaticRenderBoundsEstimate() {
        let emitter = ParticleEmitter(lifetime: 2,
                                      spawnRadius: 1,
                                      startVelocity: SIMD3<Float>(2, 0, 0),
                                      velocityRandomness: .zero,
                                      gravity: .zero,
                                      startSize: 2,
                                      endSize: 1,
                                      renderBoundsMode: .automatic)

        let estimated = emitter.estimatedRenderBoundsRadius()

        #expect(estimated > 6.4)
        #expect(abs(emitter.effectiveRenderBoundsRadius() - estimated) < 0.0001)
    }

    @Test("manual render bounds preserve legacy radius behavior")
    func manualRenderBoundsPreserveLegacyRadius() {
        let emitter = ParticleEmitter(renderBoundsRadius: 12)

        #expect(emitter.renderBoundsMode == .manual)
        #expect(emitter.effectiveRenderBoundsRadius() == 12)
    }

    @Test("render LOD scales particle submission budget by camera distance")
    func renderLODScalesSubmissionBudget() {
        let emitter = ParticleEmitter(maxRenderedParticles: 100,
                                      renderLODStartDistance: 10,
                                      renderLODEndDistance: 30,
                                      renderLODMinParticleScale: 0.25)

        #expect(emitter.renderLODScale(cameraDistance: 0) == 1)
        #expect(emitter.renderLODScale(cameraDistance: 30) == 0.25)
        #expect(emitter.effectiveMaxRenderedParticles(cameraDistance: 20,
                                                      liveParticleCount: 200) == 63)
        #expect(emitter.effectiveMaxRenderedParticles(cameraDistance: 30,
                                                      liveParticleCount: 200) == 25)
    }

    @Test("advance options scale continuous, burst, distance emission, and live cap")
    func advanceOptionsScaleEmission() {
        var continuous = ParticleEmitter(emissionRate: 10,
                                         maxParticles: 100,
                                         lifetime: 100,
                                         gravity: .zero)
        continuous.advance(deltaTime: 1, options: ParticleAdvanceOptions(emissionScale: 0.5))
        #expect(continuous.aliveCount == 5)

        var burst = ParticleEmitter(emissionRate: 0,
                                    burstCount: 3,
                                    burstInterval: 1,
                                    maxParticles: 100,
                                    lifetime: 100,
                                    gravity: .zero)
        burst.advance(deltaTime: 1, options: ParticleAdvanceOptions(burstScale: 0.5))
        #expect(burst.aliveCount == 1)
        burst.advance(deltaTime: 1, options: ParticleAdvanceOptions(burstScale: 0.5))
        #expect(burst.aliveCount == 3)

        var distance = ParticleEmitter(emissionRate: 0,
                                       distanceEmissionRate: 10,
                                       maxParticles: 100,
                                       lifetime: 100,
                                       gravity: .zero)
        distance.advance(deltaTime: 0.01, worldTransform: matrix_identity_float4x4)
        var moved = matrix_identity_float4x4
        moved.columns.3.x = 1
        distance.advance(deltaTime: 0.01,
                         worldTransform: moved,
                         options: ParticleAdvanceOptions(distanceEmissionScale: 0.25))
        #expect(distance.aliveCount == 2)

        var capped = ParticleEmitter(emissionRate: 100,
                                     maxParticles: 10,
                                     lifetime: 100,
                                     gravity: .zero)
        capped.advance(deltaTime: 1, options: ParticleAdvanceOptions(maxLiveParticleScale: 0.5))
        #expect(capped.aliveCount == 5)
    }

    @Test("schedule applies particle scalability resource during simulation")
    func scheduleAppliesParticleScalabilityResource() {
        var scene = SceneRuntime()
        scene.setResource(ParticleScalabilityResource(emissionScale: 0.25,
                                                      maxLiveParticleScale: 0.5))
        let entity = scene.createEntity()
        _ = scene.setComponent(ParticleEmitter(emissionRate: 20,
                                               maxParticles: 100,
                                               lifetime: 100,
                                               gravity: .zero),
                               for: entity)

        _ = scene.tick(deltaTime: 1)

        #expect(scene.component(ParticleEmitter.self, for: entity)?.aliveCount == 5)
    }

    @Test("emitter frame stats report spawn, expire, collision, and capacity pressure")
    func emitterFrameStatsReportSimulationWork() {
        var capped = ParticleEmitter(emissionRate: 10,
                                     maxParticles: 5,
                                     lifetime: 0.5,
                                     gravity: .zero)
        capped.advance(deltaTime: 1)
        #expect(capped.lastFrameStats.continuousSpawnedCount == 5)
        #expect(capped.lastFrameStats.capacityLimitedSpawnCount == 5)
        #expect(capped.lastFrameStats.spawnedParticleCount == 5)
        #expect(capped.lastFrameStats.liveParticleCount == 5)

        capped.advance(deltaTime: 1)
        #expect(capped.lastFrameStats.expiredParticleCount == 5)
        #expect(capped.lastFrameStats.continuousSpawnedCount == 5)
        #expect(capped.lastFrameStats.capacityLimitedSpawnCount == 5)
        #expect(capped.lastFrameStats.liveParticleCount == 5)

        var collision = ParticleEmitter(isEmitting: false,
                                        emissionRate: 0,
                                        maxParticles: 3,
                                        lifetime: 10,
                                        subEmitterTrigger: .collision,
                                        subEmitterBurstCount: 5,
                                        subEmitterLifetime: 2,
                                        originOffset: SIMD3<Float>(0, 0.5, 0),
                                        startVelocity: SIMD3<Float>(0, -1, 0),
                                        gravity: .zero,
                                        collisionMode: .localPlane,
                                        collisionPlaneY: 0)
        collision.emit(1)
        collision.advance(deltaTime: 1)
        #expect(collision.lastFrameStats.collisionCount == 1)
        #expect(collision.lastFrameStats.subEmitterSpawnedCount == 2)
        #expect(collision.lastFrameStats.capacityLimitedSpawnCount == 3)
        #expect(collision.lastFrameStats.liveParticleCount == 3)
    }

    @Test("schedule publishes aggregate particle frame stats")
    func schedulePublishesParticleFrameStats() {
        var scene = SceneRuntime()
        let a = scene.createEntity()
        let b = scene.createEntity()
        _ = scene.setComponent(ParticleEmitter(emissionRate: 10,
                                               maxParticles: 100,
                                               lifetime: 100,
                                               gravity: .zero),
                               for: a)
        _ = scene.setComponent(ParticleEmitter(emissionRate: 4,
                                               maxParticles: 100,
                                               lifetime: 100,
                                               gravity: .zero),
                               for: b)

        _ = scene.tick(deltaTime: 1)

        let stats = scene.particleFrameStats
        #expect(stats.emitterCount == 2)
        #expect(stats.activeEmitterCount == 2)
        #expect(stats.continuousSpawnedCount == 14)
        #expect(stats.spawnedParticleCount == 14)
        #expect(stats.liveParticleCount == 14)
        #expect(stats.maxParticleCount == 200)
        #expect(stats.emitterStats(for: a.rawValue)?.spawnedParticleCount == 10)
        #expect(stats.emitterStats(for: a.rawValue)?.liveParticleCount == 10)
        #expect(stats.emitterStats(for: b.rawValue)?.spawnedParticleCount == 4)
        #expect(stats.emitterStats(for: b.rawValue)?.liveParticleCount == 4)
    }

    @Test("particle scalability policy throttles simulation from previous frame pressure")
    func particleScalabilityPolicyThrottlesFromPreviousFramePressure() {
        var scene = SceneRuntime()
        scene.setResource(ParticleScalabilityPolicyResource(isEnabled: true,
                                                            targetLiveParticles: 10,
                                                            minimumScale: 0.5,
                                                            pressureStep: 0.5,
                                                            recoveryStep: 0.1))
        let entity = scene.createEntity()
        _ = scene.setComponent(ParticleEmitter(emissionRate: 40,
                                               maxParticles: 100,
                                               lifetime: 100,
                                               gravity: .zero),
                               for: entity)

        _ = scene.tick(deltaTime: 1)
        #expect(scene.component(ParticleEmitter.self, for: entity)?.aliveCount == 40)
        #expect(scene.particleScalabilityState.appliedScale == 1)
        #expect(scene.particleScalabilityState.reason == .none)

        _ = scene.tick(deltaTime: 1)
        let state = scene.particleScalabilityState
        #expect(abs(state.appliedScale - 0.5) < 0.0001)
        #expect(state.reason == .liveBudget)
        #expect(scene.component(ParticleEmitter.self, for: entity)?.aliveCount == 50)
        #expect(scene.particleFrameStats.capacityLimitedSpawnCount == 10)
    }

    @Test("particle scalability policy recovers when pressure clears")
    func particleScalabilityPolicyRecoversWhenPressureClears() {
        let policy = ParticleScalabilityPolicyResource(isEnabled: true,
                                                       targetLiveParticles: 100,
                                                       minimumScale: 0.25,
                                                       pressureStep: 0.5,
                                                       recoveryStep: 0.2)

        let state = policy.updatedState(
            previousStats: .empty,
            previousState: ParticleScalabilityStateResource(appliedScale: 0.5,
                                                            pressure: 1,
                                                            reason: .liveBudget)
        )

        #expect(abs(state.appliedScale - 0.7) < 0.0001)
        #expect(state.reason == .none)
        #expect(state.pressure == 0)
    }

    @Test("particle scalability policy reports dominant pressure reason")
    func particleScalabilityPolicyReportsDominantPressureReason() {
        let policy = ParticleScalabilityPolicyResource(isEnabled: true,
                                                       targetLiveParticles: 100,
                                                       targetSpawnedParticlesPerFrame: 20,
                                                       minimumScale: 0.25,
                                                       pressureStep: 0.2,
                                                       recoveryStep: 0.1)

        let livePressure = policy.updatedState(previousStats: ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 180, maxParticleCount: 200, liveParticleLimit: 200,
                                      continuousSpawnedCount: 24),
        ]))
        #expect(livePressure.reason == .liveBudget)
        #expect(abs(livePressure.pressure - 0.8) < 0.0001)

        let spawnPressure = policy.updatedState(previousStats: ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 120, maxParticleCount: 200, liveParticleLimit: 200,
                                      continuousSpawnedCount: 50),
        ]))
        #expect(spawnPressure.reason == .spawnBudget)
        #expect(abs(spawnPressure.pressure - 1.5) < 0.0001)

        let capacityPressure = policy.updatedState(previousStats: ParticleFrameStatsResource(emitterStats: [
            ParticleEmitterFrameStats(liveParticleCount: 10, maxParticleCount: 10, liveParticleLimit: 10,
                                      capacityLimitedSpawnCount: 1),
        ]))
        #expect(capacityPressure.reason == .capacityLimited)
        #expect(capacityPressure.pressure == 1)
    }

    @Test("particle frame stats expose live budget utilization and dropped spawns")
    func particleFrameStatsExposeLiveBudgetUtilizationAndDroppedSpawns() {
        let a = ParticleEmitterFrameStats(liveParticleCount: 45,
                                          maxParticleCount: 100,
                                          liveParticleLimit: 50,
                                          continuousSpawnedCount: 10,
                                          capacityLimitedSpawnCount: 2)
        let b = ParticleEmitterFrameStats(liveParticleCount: 25,
                                          maxParticleCount: 200,
                                          liveParticleLimit: 0,
                                          burstSpawnedCount: 5,
                                          capacityLimitedSpawnCount: 3)
        let aggregate = ParticleFrameStatsResource(emitterStats: [a, b],
                                                   emitterStatsByEntity: [11: a, 22: b])

        #expect(a.liveParticleBudgetLimit == 50)
        #expect(abs(a.liveParticleBudgetUtilization - 0.9) < 0.0001)
        #expect(a.droppedSpawnCount == 2)
        #expect(a.runtimePressureLevel == .critical)
        #expect(b.liveParticleBudgetLimit == 200)
        #expect(abs(b.liveParticleBudgetUtilization - 0.125) < 0.0001)
        #expect(b.droppedSpawnCount == 3)
        #expect(b.runtimePressureLevel == .critical)

        #expect(aggregate.liveParticleBudgetLimit == 250)
        #expect(abs(aggregate.liveParticleBudgetUtilization - 0.28) < 0.0001)
        #expect(aggregate.droppedSpawnCount == 5)
        #expect(aggregate.runtimePressureLevel == .critical)
        #expect(aggregate.emitterStats(for: 11)?.liveParticleBudgetLimit == 50)
    }

    @Test("particle frame stats classify runtime pressure levels")
    func particleFrameStatsClassifyRuntimePressureLevels() {
        let idle = ParticleEmitterFrameStats(maxParticleCount: 100)
        #expect(idle.runtimePressureLevel == .idle)

        let nominal = ParticleEmitterFrameStats(liveParticleCount: 25,
                                                maxParticleCount: 100,
                                                liveParticleLimit: 100)
        #expect(nominal.runtimePressureLevel == .nominal)

        let warning = ParticleEmitterFrameStats(liveParticleCount: 90,
                                                maxParticleCount: 100,
                                                liveParticleLimit: 100)
        #expect(warning.runtimePressureLevel == .warning)

        let overBudget = ParticleEmitterFrameStats(liveParticleCount: 100,
                                                   maxParticleCount: 100,
                                                   liveParticleLimit: 100)
        #expect(overBudget.runtimePressureLevel == .critical)

        let dropped = ParticleEmitterFrameStats(liveParticleCount: 10,
                                                maxParticleCount: 100,
                                                liveParticleLimit: 100,
                                                capacityLimitedSpawnCount: 1)
        #expect(dropped.runtimePressureLevel == .critical)

        let aggregate = ParticleFrameStatsResource(emitterStats: [nominal, warning])
        #expect(aggregate.runtimePressureLevel == .warning)
    }

    @Test("noise force deterministically accelerates particles")
    func noiseForce() {
        var emitter = ParticleEmitter(emissionRate: 0, lifetime: 10,
                                      startVelocity: .zero, gravity: .zero,
                                      noiseStrength: 2, noiseScale: 1, noiseSpeed: 0,
                                      seed: 0)
        emitter.emit(1)
        emitter.advance(deltaTime: 1)

        let p = emitter.particles[0]
        let expected = SIMD3<Float>(
            0,
            Float(sin(2.17)) * 2,
            Float(sin(4.31)) * 2
        )
        #expect(simd_length(p.velocity - expected) < 1e-4)
        #expect(simd_length(p.position - expected) < 1e-4)
    }

    @Test("SceneRuntime.advanceParticles steps every emitter component")
    func sceneAdvancesAllEmitters() {
        var scene = SceneRuntime()
        let a = scene.createEntity()
        let b = scene.createEntity()
        var e = ParticleEmitter(emissionRate: 10, maxParticles: 100, lifetime: 1000, gravity: .zero)
        e.emit(2)
        _ = scene.setComponent(e, for: a)
        _ = scene.setComponent(e, for: b)

        let stepped = scene.advanceParticles(deltaTime: 0.1)
        #expect(stepped == 2)
        #expect(scene.component(ParticleEmitter.self, for: a)!.aliveCount == 3) // 2 seeded + 1 emitted
        #expect(scene.component(ParticleEmitter.self, for: b)!.aliveCount == 3)
    }

    @Test("SceneRuntime.emitParticles triggers one emitter")
    func sceneEmitParticles() {
        var scene = SceneRuntime()
        let emitterEntity = scene.createEntity()
        let emptyEntity = scene.createEntity()
        _ = scene.setComponent(
            ParticleEmitter(emissionRate: 0, maxParticles: 5, lifetime: 10, gravity: .zero),
            for: emitterEntity
        )

        let emitted = scene.emitParticles(from: emitterEntity, count: 3)
        #expect(emitted)
        #expect(scene.component(ParticleEmitter.self, for: emitterEntity)!.aliveCount == 3)
        let missingEmitterEmitted = scene.emitParticles(from: emptyEntity, count: 3)
        #expect(!missingEmitterEmitted)
    }

    private func editModule(_ stack: inout ParticleModuleStack,
                            id: String,
                            edit: (inout ParticleEmitterModuleSettings) -> Void) throws {
        let index = try #require(stack.modules.firstIndex { $0.id == id })
        edit(&stack.modules[index].settings)
    }
}
