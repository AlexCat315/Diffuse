import SIMDCompat

public enum ParticleModuleStage: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case spawn
    case initialize
    case update
    case render
    case event
    case simulation
}

public struct ParticleModuleStack: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaultModuleIDs = [
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
    ]

    public var version: Int
    public var modules: [ParticleEmitterModule]

    public init(version: Int = Self.currentVersion, modules: [ParticleEmitterModule] = []) {
        self.version = max(1, version)
        self.modules = modules
    }

    public init(emitter: ParticleEmitter) {
        self.init(modules: [
            ParticleEmitterModule(id: "emission",
                                  stage: .spawn,
                                  displayName: "Emission",
                                  settings: .emission(ParticleEmissionModule(emitter))),
            ParticleEmitterModule(id: "shape",
                                  stage: .spawn,
                                  displayName: "Shape",
                                  settings: .shape(ParticleShapeModule(emitter))),
            ParticleEmitterModule(id: "velocity",
                                  stage: .initialize,
                                  displayName: "Velocity",
                                  settings: .velocity(ParticleVelocityModule(emitter))),
            ParticleEmitterModule(id: "forces",
                                  stage: .update,
                                  displayName: "Forces",
                                  settings: .forces(ParticleForcesModule(emitter))),
            ParticleEmitterModule(id: "collision",
                                  stage: .update,
                                  displayName: "Collision",
                                  settings: .collision(ParticleCollisionModule(emitter))),
            ParticleEmitterModule(id: "appearance",
                                  stage: .initialize,
                                  displayName: "Appearance",
                                  settings: .appearance(ParticleAppearanceModule(emitter))),
            ParticleEmitterModule(id: "textureSheet",
                                  stage: .render,
                                  displayName: "Texture Sheet",
                                  settings: .textureSheet(ParticleTextureSheetModule(emitter))),
            ParticleEmitterModule(id: "renderer",
                                  stage: .render,
                                  displayName: "Renderer",
                                  settings: .renderer(ParticleRendererModule(emitter))),
            ParticleEmitterModule(id: "trails",
                                  stage: .render,
                                  displayName: "Trails",
                                  settings: .trails(ParticleTrailsModule(emitter))),
            ParticleEmitterModule(id: "subEmitters",
                                  stage: .event,
                                  displayName: "Sub-Emitters",
                                  settings: .subEmitters(ParticleSubEmittersModule(emitter))),
            ParticleEmitterModule(id: "gpuSimulation",
                                  stage: .simulation,
                                  displayName: "GPU Simulation",
                                  settings: .gpuSimulation(ParticleGPUSimulationModule(emitter))),
        ])
    }

    public init(emitter: ParticleEmitter, preserving template: ParticleModuleStack?) {
        let current = ParticleModuleStack(emitter: emitter)
        guard let template else {
            self = current
            return
        }

        var currentByID: [String: ParticleEmitterModule] = [:]
        for module in current.modules {
            currentByID[module.id] = module
        }

        var usedIDs: Set<String> = []
        var modules: [ParticleEmitterModule] = []
        modules.reserveCapacity(max(template.modules.count, current.modules.count))

        for authored in template.modules {
            if var refreshed = currentByID[authored.id] {
                refreshed.isEnabled = authored.isEnabled
                refreshed.isExpanded = authored.isExpanded
                if !authored.isEnabled {
                    refreshed.settings = authored.settings
                }
                modules.append(refreshed)
                usedIDs.insert(authored.id)
            } else {
                modules.append(authored)
                usedIDs.insert(authored.id)
            }
        }

        for module in current.modules where !usedIDs.contains(module.id) {
            modules.append(module)
        }

        self.init(version: template.version, modules: modules)
    }

    public mutating func moveModule(from sourceIndex: Int, to destinationIndex: Int) {
        guard modules.indices.contains(sourceIndex),
              modules.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        let module = modules.remove(at: sourceIndex)
        modules.insert(module, at: destinationIndex)
    }

    public mutating func resetAuthoringState() {
        let order = Dictionary(uniqueKeysWithValues: Self.defaultModuleIDs.enumerated().map { ($0.element, $0.offset) })
        modules.sort { lhs, rhs in
            let lhsOrder = order[lhs.id] ?? Int.max
            let rhsOrder = order[rhs.id] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.id < rhs.id
        }
        for index in modules.indices {
            modules[index].isEnabled = true
            modules[index].isExpanded = false
        }
    }
}

public struct ParticleEmitterModule: Codable, Sendable, Equatable {
    public var id: String
    public var stage: ParticleModuleStage
    public var displayName: String
    public var isEnabled: Bool
    public var isExpanded: Bool
    public var settings: ParticleEmitterModuleSettings

    public init(id: String,
                stage: ParticleModuleStage,
                displayName: String,
                isEnabled: Bool = true,
                isExpanded: Bool = false,
                settings: ParticleEmitterModuleSettings) {
        self.id = id
        self.stage = stage
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.isExpanded = isExpanded
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case stage
        case displayName
        case isEnabled
        case isExpanded
        case settings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        stage = try container.decode(ParticleModuleStage.self, forKey: .stage)
        displayName = try container.decode(String.self, forKey: .displayName)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? false
        settings = try container.decode(ParticleEmitterModuleSettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(stage, forKey: .stage)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isExpanded, forKey: .isExpanded)
        try container.encode(settings, forKey: .settings)
    }
}

public enum ParticleModuleIssueSeverity: String, Codable, Sendable, Equatable, Hashable {
    case info
    case warning
    case error
}

public struct ParticleModuleIssue: Codable, Sendable, Equatable, Hashable {
    public var moduleID: String
    public var severity: ParticleModuleIssueSeverity
    public var code: String
    public var message: String

    public init(moduleID: String,
                severity: ParticleModuleIssueSeverity,
                code: String,
                message: String) {
        self.moduleID = moduleID
        self.severity = severity
        self.code = code
        self.message = message
    }
}

public enum ParticleEmitterModuleSettings: Codable, Sendable, Equatable {
    case emission(ParticleEmissionModule)
    case shape(ParticleShapeModule)
    case velocity(ParticleVelocityModule)
    case forces(ParticleForcesModule)
    case collision(ParticleCollisionModule)
    case appearance(ParticleAppearanceModule)
    case textureSheet(ParticleTextureSheetModule)
    case renderer(ParticleRendererModule)
    case trails(ParticleTrailsModule)
    case subEmitters(ParticleSubEmittersModule)
    case gpuSimulation(ParticleGPUSimulationModule)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum ModuleType: String, Codable {
        case emission
        case shape
        case velocity
        case forces
        case collision
        case appearance
        case textureSheet
        case renderer
        case trails
        case subEmitters
        case gpuSimulation
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .emission(module):
            try container.encode(ModuleType.emission, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .shape(module):
            try container.encode(ModuleType.shape, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .velocity(module):
            try container.encode(ModuleType.velocity, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .forces(module):
            try container.encode(ModuleType.forces, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .collision(module):
            try container.encode(ModuleType.collision, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .appearance(module):
            try container.encode(ModuleType.appearance, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .textureSheet(module):
            try container.encode(ModuleType.textureSheet, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .renderer(module):
            try container.encode(ModuleType.renderer, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .trails(module):
            try container.encode(ModuleType.trails, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .subEmitters(module):
            try container.encode(ModuleType.subEmitters, forKey: .type)
            try container.encode(module, forKey: .payload)
        case let .gpuSimulation(module):
            try container.encode(ModuleType.gpuSimulation, forKey: .type)
            try container.encode(module, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ModuleType.self, forKey: .type) {
        case .emission:
            self = .emission(try container.decode(ParticleEmissionModule.self, forKey: .payload))
        case .shape:
            self = .shape(try container.decode(ParticleShapeModule.self, forKey: .payload))
        case .velocity:
            self = .velocity(try container.decode(ParticleVelocityModule.self, forKey: .payload))
        case .forces:
            self = .forces(try container.decode(ParticleForcesModule.self, forKey: .payload))
        case .collision:
            self = .collision(try container.decode(ParticleCollisionModule.self, forKey: .payload))
        case .appearance:
            self = .appearance(try container.decode(ParticleAppearanceModule.self, forKey: .payload))
        case .textureSheet:
            self = .textureSheet(try container.decode(ParticleTextureSheetModule.self, forKey: .payload))
        case .renderer:
            self = .renderer(try container.decode(ParticleRendererModule.self, forKey: .payload))
        case .trails:
            self = .trails(try container.decode(ParticleTrailsModule.self, forKey: .payload))
        case .subEmitters:
            self = .subEmitters(try container.decode(ParticleSubEmittersModule.self, forKey: .payload))
        case .gpuSimulation:
            self = .gpuSimulation(try container.decode(ParticleGPUSimulationModule.self, forKey: .payload))
        }
    }
}

public struct ParticleEmissionModule: Codable, Sendable, Equatable {
    public var isEmitting: Bool
    public var looping: Bool
    public var duration: Float
    public var prewarmTime: Float
    public var prewarmStep: Float
    public var emissionRate: Float
    public var emissionRateCurve: ParticleCurve
    public var distanceEmissionRate: Float
    public var distanceEmissionRateCurve: ParticleCurve
    public var burstCount: Int
    public var burstInterval: Float
    public var maxParticles: Int
    public var maxRenderedParticles: Int

    public init(_ emitter: ParticleEmitter) {
        self.isEmitting = emitter.isEmitting
        self.looping = emitter.looping
        self.duration = emitter.duration
        self.prewarmTime = emitter.prewarmTime
        self.prewarmStep = emitter.prewarmStep
        self.emissionRate = emitter.emissionRate
        self.emissionRateCurve = emitter.emissionRateCurve
        self.distanceEmissionRate = emitter.distanceEmissionRate
        self.distanceEmissionRateCurve = emitter.distanceEmissionRateCurve
        self.burstCount = emitter.burstCount
        self.burstInterval = emitter.burstInterval
        self.maxParticles = emitter.maxParticles
        self.maxRenderedParticles = emitter.maxRenderedParticles
    }
}

public struct ParticleShapeModule: Codable, Sendable, Equatable {
    public var originOffset: SIMD3<Float>
    public var spawnRadius: Float
    public var emissionShape: ParticleEmissionShape
    public var boxHalfExtents: SIMD3<Float>
    public var coneRadius: Float
    public var coneHeight: Float

    public init(_ emitter: ParticleEmitter) {
        self.originOffset = emitter.originOffset
        self.spawnRadius = emitter.spawnRadius
        self.emissionShape = emitter.emissionShape
        self.boxHalfExtents = emitter.boxHalfExtents
        self.coneRadius = emitter.coneRadius
        self.coneHeight = emitter.coneHeight
    }
}

public struct ParticleVelocityModule: Codable, Sendable, Equatable {
    public var startVelocity: SIMD3<Float>
    public var velocityRandomness: SIMD3<Float>
    public var velocityInheritance: Float

    public init(_ emitter: ParticleEmitter) {
        self.startVelocity = emitter.startVelocity
        self.velocityRandomness = emitter.velocityRandomness
        self.velocityInheritance = emitter.velocityInheritance
    }
}

public struct ParticleForcesModule: Codable, Sendable, Equatable {
    public var gravity: SIMD3<Float>
    public var noiseStrength: Float
    public var noiseScale: Float
    public var noiseSpeed: Float
    public var forceMode: ParticleForceMode
    public var forceCenter: SIMD3<Float>
    public var forceAxis: SIMD3<Float>
    public var forceRadius: Float
    public var forceStrength: Float
    public var forceFalloff: Float
    public var vectorFieldMode: ParticleVectorFieldMode
    public var vectorFieldDirection: SIMD3<Float>
    public var vectorFieldStrength: Float
    public var vectorFieldScale: Float
    public var vectorFieldScrollSpeed: Float

    public init(_ emitter: ParticleEmitter) {
        self.gravity = emitter.gravity
        self.noiseStrength = emitter.noiseStrength
        self.noiseScale = emitter.noiseScale
        self.noiseSpeed = emitter.noiseSpeed
        self.forceMode = emitter.forceMode
        self.forceCenter = emitter.forceCenter
        self.forceAxis = emitter.forceAxis
        self.forceRadius = emitter.forceRadius
        self.forceStrength = emitter.forceStrength
        self.forceFalloff = emitter.forceFalloff
        self.vectorFieldMode = emitter.vectorFieldMode
        self.vectorFieldDirection = emitter.vectorFieldDirection
        self.vectorFieldStrength = emitter.vectorFieldStrength
        self.vectorFieldScale = emitter.vectorFieldScale
        self.vectorFieldScrollSpeed = emitter.vectorFieldScrollSpeed
    }
}

public struct ParticleCollisionModule: Codable, Sendable, Equatable {
    public var collisionMode: ParticleCollisionMode
    public var collisionPlaneY: Float
    public var collisionRestitution: Float
    public var collisionDamping: Float

    public init(_ emitter: ParticleEmitter) {
        self.collisionMode = emitter.collisionMode
        self.collisionPlaneY = emitter.collisionPlaneY
        self.collisionRestitution = emitter.collisionRestitution
        self.collisionDamping = emitter.collisionDamping
    }
}

public struct ParticleAppearanceModule: Codable, Sendable, Equatable {
    public var lifetime: Float
    public var lifetimeRandomness: Float
    public var startSize: Float
    public var endSize: Float
    public var sizeRandomness: Float
    public var startRotation: Float
    public var rotationRandomness: Float
    public var angularVelocity: Float
    public var angularVelocityRandomness: Float
    public var sizeCurve: ParticleCurve
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>
    public var colorCurve: ParticleCurve
    public var blendMode: ParticleBlendMode

    public init(_ emitter: ParticleEmitter) {
        self.lifetime = emitter.lifetime
        self.lifetimeRandomness = emitter.lifetimeRandomness
        self.startSize = emitter.startSize
        self.endSize = emitter.endSize
        self.sizeRandomness = emitter.sizeRandomness
        self.startRotation = emitter.startRotation
        self.rotationRandomness = emitter.rotationRandomness
        self.angularVelocity = emitter.angularVelocity
        self.angularVelocityRandomness = emitter.angularVelocityRandomness
        self.sizeCurve = emitter.sizeCurve
        self.startColor = emitter.startColor
        self.endColor = emitter.endColor
        self.colorCurve = emitter.colorCurve
        self.blendMode = emitter.blendMode
    }
}

public struct ParticleTextureSheetModule: Codable, Sendable, Equatable {
    public var textureAssetID: String?
    public var texturePath: String?
    public var columns: Int
    public var rows: Int
    public var frameCount: Int
    public var frameRate: Float
    public var playbackMode: ParticleTextureSheetPlaybackMode
    public var startFrame: Int
    public var frameRandomness: Int

    public init(_ emitter: ParticleEmitter) {
        self.textureAssetID = emitter.textureAssetID
        self.texturePath = emitter.texturePath
        self.columns = emitter.textureSheetColumns
        self.rows = emitter.textureSheetRows
        self.frameCount = emitter.textureSheetFrameCount
        self.frameRate = emitter.textureSheetFrameRate
        self.playbackMode = emitter.textureSheetPlaybackMode
        self.startFrame = emitter.textureSheetStartFrame
        self.frameRandomness = emitter.textureSheetFrameRandomness
    }
}

public struct ParticleRendererModule: Codable, Sendable, Equatable {
    public var renderMode: ParticleRenderMode
    public var sortMode: ParticleSortMode
    public var renderAlignment: ParticleRenderAlignment
    public var velocityStretchScale: Float
    public var velocityStretchMax: Float
    public var maxRenderDistance: Float
    public var renderDistanceFadeRange: Float
    public var renderLODStartDistance: Float
    public var renderLODEndDistance: Float
    public var renderLODMinParticleScale: Float
    public var renderBoundsMode: ParticleRenderBoundsMode
    public var renderBoundsRadius: Float

    public init(_ emitter: ParticleEmitter) {
        self.renderMode = emitter.renderMode
        self.sortMode = emitter.sortMode
        self.renderAlignment = emitter.renderAlignment
        self.velocityStretchScale = emitter.velocityStretchScale
        self.velocityStretchMax = emitter.velocityStretchMax
        self.maxRenderDistance = emitter.maxRenderDistance
        self.renderDistanceFadeRange = emitter.renderDistanceFadeRange
        self.renderLODStartDistance = emitter.renderLODStartDistance
        self.renderLODEndDistance = emitter.renderLODEndDistance
        self.renderLODMinParticleScale = emitter.renderLODMinParticleScale
        self.renderBoundsMode = emitter.renderBoundsMode
        self.renderBoundsRadius = emitter.renderBoundsRadius
    }
}

public struct ParticleTrailsModule: Codable, Sendable, Equatable {
    public var ribbonWidthScale: Float
    public var ribbonTailWidthScale: Float
    public var ribbonTailAlphaScale: Float
    public var ribbonMaxSegmentLength: Float
    public var ribbonJoinOverlapScale: Float
    public var ribbonSmoothingSegments: Int
    public var ribbonTextureTiling: Float
    public var ribbonTextureOffset: Float
    public var trailLength: Float
    public var trailSegments: Int
    public var trailEndSizeScale: Float
    public var trailEndAlphaScale: Float

    public init(_ emitter: ParticleEmitter) {
        self.ribbonWidthScale = emitter.ribbonWidthScale
        self.ribbonTailWidthScale = emitter.ribbonTailWidthScale
        self.ribbonTailAlphaScale = emitter.ribbonTailAlphaScale
        self.ribbonMaxSegmentLength = emitter.ribbonMaxSegmentLength
        self.ribbonJoinOverlapScale = emitter.ribbonJoinOverlapScale
        self.ribbonSmoothingSegments = emitter.ribbonSmoothingSegments
        self.ribbonTextureTiling = emitter.ribbonTextureTiling
        self.ribbonTextureOffset = emitter.ribbonTextureOffset
        self.trailLength = emitter.trailLength
        self.trailSegments = emitter.trailSegments
        self.trailEndSizeScale = emitter.trailEndSizeScale
        self.trailEndAlphaScale = emitter.trailEndAlphaScale
    }
}

public struct ParticleSubEmittersModule: Codable, Sendable, Equatable {
    public var legacyTrigger: ParticleSubEmitterTrigger
    public var legacyBurstCount: Int
    public var legacyProbability: Float
    public var legacyMaxDepth: Int
    public var legacyInheritVelocity: Float
    public var legacyLifetime: Float
    public var legacyStartVelocity: SIMD3<Float>
    public var legacyVelocityRandomness: SIMD3<Float>
    public var legacyStartSize: Float
    public var legacyEndSize: Float
    public var legacyStartColor: SIMD4<Float>
    public var legacyEndColor: SIMD4<Float>
    public var rules: [ParticleSubEmitter]

    public init(_ emitter: ParticleEmitter) {
        self.legacyTrigger = emitter.subEmitterTrigger
        self.legacyBurstCount = emitter.subEmitterBurstCount
        self.legacyProbability = emitter.subEmitterProbability
        self.legacyMaxDepth = emitter.subEmitterMaxDepth
        self.legacyInheritVelocity = emitter.subEmitterInheritVelocity
        self.legacyLifetime = emitter.subEmitterLifetime
        self.legacyStartVelocity = emitter.subEmitterStartVelocity
        self.legacyVelocityRandomness = emitter.subEmitterVelocityRandomness
        self.legacyStartSize = emitter.subEmitterStartSize
        self.legacyEndSize = emitter.subEmitterEndSize
        self.legacyStartColor = emitter.subEmitterStartColor
        self.legacyEndColor = emitter.subEmitterEndColor
        self.rules = emitter.subEmitters
    }
}

public struct ParticleGPUSimulationModule: Codable, Sendable, Equatable {
    public var simulationSpace: ParticleSimulationSpace
    public var simulationBackend: ParticleSimulationBackend
    public var workgroupSize: Int

    public init(_ emitter: ParticleEmitter) {
        self.simulationSpace = emitter.simulationSpace
        self.simulationBackend = emitter.simulationBackend
        self.workgroupSize = emitter.gpuSimulationWorkgroupSize
    }
}

public extension ParticleModuleStack {
    func validationIssues() -> [ParticleModuleIssue] {
        var issues: [ParticleModuleIssue] = []
        var seenIDs: Set<String> = []

        for module in modules {
            if !seenIDs.insert(module.id).inserted {
                issues.append(ParticleModuleIssue(moduleID: module.id,
                                                  severity: .warning,
                                                  code: "duplicateModule",
                                                  message: "Duplicate module id '\(module.id)' will make authoring order ambiguous."))
            }
        }

        for id in Self.defaultModuleIDs where !seenIDs.contains(id) {
            issues.append(ParticleModuleIssue(moduleID: id,
                                              severity: .warning,
                                              code: "missingModule",
                                              message: "Default module '\(id)' is missing from this stack."))
        }

        for module in modules where module.isEnabled {
            issues.append(contentsOf: module.validationIssues())
        }

        return issues
    }

    mutating func repairValidationIssues() {
        for index in modules.indices where modules[index].isEnabled {
            modules[index].settings.repairValidationIssues()
        }
    }
}

public extension ParticleEmitterModule {
    func validationIssues() -> [ParticleModuleIssue] {
        guard isEnabled else { return [] }
        return settings.validationIssues(moduleID: id)
    }
}

public extension ParticleEmitter {
    var moduleValidationIssues: [ParticleModuleIssue] {
        var issues = moduleStack.validationIssues()
        guard moduleStack.modules.contains(where: { module in
            module.id == "gpuSimulation" && module.isEnabled
        }) else {
            return issues
        }

        let plan = gpuSimulationPlan
        switch plan.status {
        case .disabled, .supported:
            break
        case .fallbackToCPU:
            issues.append(ParticleModuleIssue(moduleID: "gpuSimulation",
                                              severity: .warning,
                                              code: "gpuFallbackToCPU",
                                              message: "GPU simulation will fall back to CPU: \(plan.unsupportedReasonSummary)."))
        case .requiredButUnsupported:
            issues.append(ParticleModuleIssue(moduleID: "gpuSimulation",
                                              severity: .error,
                                              code: "gpuRequiredButUnsupported",
                                              message: "GPU simulation is required but unsupported: \(plan.unsupportedReasonSummary)."))
        }
        return issues
    }
}

private extension ParticleEmitterModuleSettings {
    func validationIssues(moduleID: String) -> [ParticleModuleIssue] {
        switch self {
        case let .emission(settings):
            return validateEmission(settings, moduleID: moduleID)
        case let .shape(settings):
            return validateShape(settings, moduleID: moduleID)
        case let .velocity(settings):
            return validateVelocity(settings, moduleID: moduleID)
        case let .forces(settings):
            return validateForces(settings, moduleID: moduleID)
        case let .collision(settings):
            return validateCollision(settings, moduleID: moduleID)
        case let .appearance(settings):
            return validateAppearance(settings, moduleID: moduleID)
        case let .textureSheet(settings):
            return validateTextureSheet(settings, moduleID: moduleID)
        case let .renderer(settings):
            return validateRenderer(settings, moduleID: moduleID)
        case let .trails(settings):
            return validateTrails(settings, moduleID: moduleID)
        case let .subEmitters(settings):
            return validateSubEmitters(settings, moduleID: moduleID)
        case let .gpuSimulation(settings):
            return validateGPUSimulation(settings, moduleID: moduleID)
        }
    }

    mutating func repairValidationIssues() {
        switch self {
        case var .emission(settings):
            settings.maxParticles = max(1, settings.maxParticles)
            settings.maxRenderedParticles = max(0, min(settings.maxRenderedParticles, settings.maxParticles))
            settings.prewarmTime = max(0, settings.prewarmTime)
            if settings.prewarmTime > 0 {
                settings.prewarmStep = max(1.0 / 240.0, settings.prewarmStep)
            }
            settings.emissionRate = max(0, settings.emissionRate)
            settings.distanceEmissionRate = max(0, settings.distanceEmissionRate)
            settings.burstCount = max(0, settings.burstCount)
            settings.burstInterval = max(0, settings.burstInterval)
            self = .emission(settings)
        case var .shape(settings):
            settings.spawnRadius = max(0, settings.spawnRadius)
            settings.boxHalfExtents = SIMD3<Float>(
                max(0.0001, settings.boxHalfExtents.x),
                max(0.0001, settings.boxHalfExtents.y),
                max(0.0001, settings.boxHalfExtents.z)
            )
            settings.coneRadius = max(0.0001, settings.coneRadius)
            settings.coneHeight = max(0.0001, settings.coneHeight)
            self = .shape(settings)
        case var .velocity(settings):
            settings.velocityInheritance = max(0, settings.velocityInheritance)
            self = .velocity(settings)
        case var .forces(settings):
            settings.noiseStrength = max(0, settings.noiseStrength)
            settings.noiseScale = max(0.0001, settings.noiseScale)
            settings.noiseSpeed = max(0, settings.noiseSpeed)
            settings.forceRadius = max(0, settings.forceRadius)
            settings.forceFalloff = max(0, settings.forceFalloff)
            settings.vectorFieldScale = max(0.0001, settings.vectorFieldScale)
            settings.vectorFieldScrollSpeed = max(0, settings.vectorFieldScrollSpeed)
            self = .forces(settings)
        case var .collision(settings):
            settings.collisionRestitution = simd_clamp(settings.collisionRestitution, 0, 1)
            settings.collisionDamping = simd_clamp(settings.collisionDamping, 0, 1)
            self = .collision(settings)
        case var .appearance(settings):
            settings.lifetime = max(0.0001, settings.lifetime)
            settings.lifetimeRandomness = max(0, settings.lifetimeRandomness)
            settings.startSize = max(0, settings.startSize)
            settings.endSize = max(0, settings.endSize)
            settings.sizeRandomness = max(0, settings.sizeRandomness)
            settings.rotationRandomness = max(0, settings.rotationRandomness)
            settings.angularVelocityRandomness = max(0, settings.angularVelocityRandomness)
            self = .appearance(settings)
        case var .textureSheet(settings):
            settings.columns = max(1, settings.columns)
            settings.rows = max(1, settings.rows)
            let cellCount = max(1, settings.columns * settings.rows)
            settings.frameCount = min(max(1, settings.frameCount), cellCount)
            settings.frameRate = max(0, settings.frameRate)
            settings.startFrame = min(max(0, settings.startFrame), cellCount - 1)
            settings.frameRandomness = max(0, settings.frameRandomness)
            self = .textureSheet(settings)
        case var .renderer(settings):
            settings.velocityStretchScale = max(0, settings.velocityStretchScale)
            settings.velocityStretchMax = max(1, settings.velocityStretchMax)
            settings.maxRenderDistance = max(0, settings.maxRenderDistance)
            settings.renderDistanceFadeRange = max(0, settings.renderDistanceFadeRange)
            if settings.maxRenderDistance > 0 {
                settings.renderDistanceFadeRange = min(settings.renderDistanceFadeRange,
                                                       settings.maxRenderDistance)
            }
            settings.renderLODStartDistance = max(0, settings.renderLODStartDistance)
            settings.renderLODEndDistance = max(0, settings.renderLODEndDistance)
            if settings.renderLODEndDistance > 0,
               settings.renderLODStartDistance > settings.renderLODEndDistance {
                settings.renderLODStartDistance = settings.renderLODEndDistance
            }
            settings.renderLODMinParticleScale = simd_clamp(settings.renderLODMinParticleScale, 0, 1)
            if settings.renderBoundsMode != .disabled {
                settings.renderBoundsRadius = max(0.0001, settings.renderBoundsRadius)
            } else {
                settings.renderBoundsRadius = max(0, settings.renderBoundsRadius)
            }
            self = .renderer(settings)
        case var .trails(settings):
            settings.ribbonWidthScale = max(0, settings.ribbonWidthScale)
            settings.ribbonTailWidthScale = max(0, settings.ribbonTailWidthScale)
            settings.ribbonTailAlphaScale = simd_clamp(settings.ribbonTailAlphaScale, 0, 1)
            settings.ribbonMaxSegmentLength = max(0, settings.ribbonMaxSegmentLength)
            settings.ribbonJoinOverlapScale = max(0, settings.ribbonJoinOverlapScale)
            settings.ribbonSmoothingSegments = min(16, max(1, settings.ribbonSmoothingSegments))
            settings.ribbonTextureTiling = max(0, settings.ribbonTextureTiling)
            settings.trailLength = max(0, settings.trailLength)
            if settings.trailLength > 0 {
                settings.trailSegments = max(1, settings.trailSegments)
            } else {
                settings.trailSegments = max(0, settings.trailSegments)
            }
            settings.trailEndSizeScale = max(0, settings.trailEndSizeScale)
            settings.trailEndAlphaScale = simd_clamp(settings.trailEndAlphaScale, 0, 1)
            self = .trails(settings)
        case var .subEmitters(settings):
            settings.legacyBurstCount = settings.legacyTrigger == .none
                ? max(0, settings.legacyBurstCount)
                : max(1, settings.legacyBurstCount)
            settings.legacyProbability = simd_clamp(settings.legacyProbability, 0, 1)
            settings.legacyMaxDepth = max(0, settings.legacyMaxDepth)
            settings.legacyInheritVelocity = max(0, settings.legacyInheritVelocity)
            settings.legacyLifetime = max(0.0001, settings.legacyLifetime)
            settings.legacyStartSize = max(0, settings.legacyStartSize)
            settings.legacyEndSize = max(0, settings.legacyEndSize)
            settings.rules = settings.rules.map(repairedSubEmitter)
            self = .subEmitters(settings)
        case var .gpuSimulation(settings):
            settings.workgroupSize = min(max(1, settings.workgroupSize),
                                         ParticleGPUSimulationPlan.maximumWorkgroupSize)
            self = .gpuSimulation(settings)
        }
    }
}

private func repairedSubEmitter(_ rule: ParticleSubEmitter) -> ParticleSubEmitter {
    ParticleSubEmitter(trigger: rule.trigger,
                       burstCount: rule.trigger == .none ? max(0, rule.burstCount) : max(1, rule.burstCount),
                       probability: simd_clamp(rule.probability, 0, 1),
                       maxDepth: max(0, rule.maxDepth),
                       inheritVelocity: max(0, rule.inheritVelocity),
                       lifetime: max(0.0001, rule.lifetime),
                       startVelocity: rule.startVelocity,
                       velocityRandomness: rule.velocityRandomness,
                       startSize: max(0, rule.startSize),
                       endSize: max(0, rule.endSize),
                       startColor: rule.startColor,
                       endColor: rule.endColor)
}

private extension ParticleGPUSimulationPlan {
    var unsupportedReasonSummary: String {
        unsupportedReasons.map(\.displayName).joined(separator: ", ")
    }
}

private extension ParticleGPUSimulationUnsupportedReason {
    var displayName: String {
        switch self {
        case .backendCPU:
            return "CPU backend"
        case .noParticleCapacity:
            return "no particle capacity"
        case .eventSubEmitters:
            return "event sub-emitters"
        case .distanceEmission:
            return "distance emission"
        case .noise:
            return "noise"
        case .forceFields:
            return "force fields"
        case .collisions:
            return "collisions"
        case .angularVelocity:
            return "angular velocity"
        }
    }
}

private func validateEmission(_ settings: ParticleEmissionModule,
                              moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.maxParticles <= 0 {
        issues.append(issue(moduleID, .error, "noParticleCapacity",
                            "Max particles must be greater than zero."))
    }
    if settings.isEmitting
        && settings.emissionRate <= 0
        && settings.distanceEmissionRate <= 0
        && settings.burstCount <= 0 {
        issues.append(issue(moduleID, .warning, "noSpawnSource",
                            "Emitter is enabled but has no continuous, distance, or burst spawn source."))
    }
    if settings.maxParticles > 0 && settings.maxRenderedParticles > settings.maxParticles {
        issues.append(issue(moduleID, .info, "renderCapExceedsCapacity",
                            "Max rendered particles exceeds simulation capacity and will have no extra effect."))
    }
    if settings.prewarmTime > 0 && settings.prewarmStep <= 0 {
        issues.append(issue(moduleID, .error, "invalidPrewarmStep",
                            "Prewarm step must be greater than zero."))
    }
    return issues
}

private func validateShape(_ settings: ParticleShapeModule,
                           moduleID: String) -> [ParticleModuleIssue] {
    switch settings.emissionShape {
    case .sphere where settings.spawnRadius < 0:
        return [issue(moduleID, .warning, "negativeSpawnRadius",
                      "Sphere radius is negative and will be clamped.")]
    case .box where settings.boxHalfExtents.x <= 0
        || settings.boxHalfExtents.y <= 0
        || settings.boxHalfExtents.z <= 0:
        return [issue(moduleID, .warning, "invalidBoxExtents",
                      "Box half extents should be greater than zero on every axis.")]
    case .cone where settings.coneRadius <= 0 || settings.coneHeight <= 0:
        return [issue(moduleID, .warning, "invalidConeShape",
                      "Cone radius and height should be greater than zero.")]
    default:
        return []
    }
}

private func validateVelocity(_ settings: ParticleVelocityModule,
                              moduleID: String) -> [ParticleModuleIssue] {
    settings.velocityInheritance < 0
        ? [issue(moduleID, .warning, "negativeVelocityInheritance",
                 "Velocity inheritance is negative and will be clamped.")]
        : []
}

private func validateForces(_ settings: ParticleForcesModule,
                            moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.noiseStrength > 0 && settings.noiseScale <= 0 {
        issues.append(issue(moduleID, .error, "invalidNoiseScale",
                            "Noise scale must be greater than zero when noise is active."))
    }
    if settings.forceMode != .none && settings.forceRadius <= 0 {
        issues.append(issue(moduleID, .warning, "invalidForceRadius",
                            "Force radius should be greater than zero when a force field is active."))
    }
    if settings.forceMode != .none && settings.forceFalloff < 0 {
        issues.append(issue(moduleID, .warning, "negativeForceFalloff",
                            "Force falloff is negative and will be clamped."))
    }
    if settings.vectorFieldMode != .none && settings.vectorFieldScale <= 0 {
        issues.append(issue(moduleID, .error, "invalidVectorFieldScale",
                            "Vector field scale must be greater than zero when a vector field is active."))
    }
    return issues
}

private func validateCollision(_ settings: ParticleCollisionModule,
                               moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.collisionRestitution < 0 || settings.collisionRestitution > 1 {
        issues.append(issue(moduleID, .warning, "restitutionOutOfRange",
                            "Restitution should be between 0 and 1."))
    }
    if settings.collisionDamping < 0 || settings.collisionDamping > 1 {
        issues.append(issue(moduleID, .warning, "dampingOutOfRange",
                            "Damping should be between 0 and 1."))
    }
    return issues
}

private func validateAppearance(_ settings: ParticleAppearanceModule,
                                moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.lifetime <= 0 {
        issues.append(issue(moduleID, .error, "invalidLifetime",
                            "Particle lifetime must be greater than zero."))
    }
    if settings.startSize < 0 || settings.endSize < 0 {
        issues.append(issue(moduleID, .warning, "negativeParticleSize",
                            "Particle sizes should not be negative."))
    }
    if settings.sizeRandomness < 0 || settings.lifetimeRandomness < 0 {
        issues.append(issue(moduleID, .warning, "negativeRandomness",
                            "Randomness values should not be negative."))
    }
    return issues
}

private func validateTextureSheet(_ settings: ParticleTextureSheetModule,
                                  moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    let columns = max(0, settings.columns)
    let rows = max(0, settings.rows)
    let cellCount = columns * rows
    if settings.columns <= 0 || settings.rows <= 0 || settings.frameCount <= 0 {
        issues.append(issue(moduleID, .error, "invalidTextureSheet",
                            "Texture sheet columns, rows, and frame count must be greater than zero."))
    }
    if cellCount > 0 && settings.frameCount > cellCount {
        issues.append(issue(moduleID, .warning, "frameCountExceedsCells",
                            "Frame count exceeds the number of cells in the texture sheet."))
    }
    if cellCount > 0 && settings.startFrame >= cellCount {
        issues.append(issue(moduleID, .warning, "startFrameOutOfRange",
                            "Start frame is outside the texture sheet cell range."))
    }
    if settings.frameRandomness < 0 {
        issues.append(issue(moduleID, .warning, "negativeFrameRandomness",
                            "Frame randomness is negative and will be clamped."))
    }
    return issues
}

private func validateRenderer(_ settings: ParticleRendererModule,
                              moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.renderLODEndDistance > 0
        && settings.renderLODStartDistance > settings.renderLODEndDistance {
        issues.append(issue(moduleID, .warning, "invalidLODRange",
                            "LOD start distance should not exceed LOD end distance."))
    }
    if settings.maxRenderDistance > 0
        && settings.renderDistanceFadeRange > settings.maxRenderDistance {
        issues.append(issue(moduleID, .warning, "fadeRangeExceedsDistance",
                            "Distance fade range exceeds max render distance."))
    }
    if settings.renderBoundsMode != .disabled && settings.renderBoundsRadius <= 0 {
        issues.append(issue(moduleID, .warning, "invalidRenderBounds",
                            "Explicit render bounds need a radius greater than zero."))
    }
    if settings.velocityStretchScale > 0 && settings.velocityStretchMax <= 0 {
        issues.append(issue(moduleID, .error, "invalidVelocityStretch",
                            "Velocity stretch max must be greater than zero."))
    }
    return issues
}

private func validateTrails(_ settings: ParticleTrailsModule,
                            moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.trailLength > 0 && settings.trailSegments <= 0 {
        issues.append(issue(moduleID, .warning, "trailWithoutSamples",
                            "Trail length is active but trail segments is zero."))
    }
    if settings.ribbonSmoothingSegments <= 0 {
        issues.append(issue(moduleID, .warning, "invalidRibbonSmoothing",
                            "Ribbon smoothing segments should be at least one."))
    }
    if settings.ribbonTailAlphaScale < 0 || settings.ribbonTailAlphaScale > 1 {
        issues.append(issue(moduleID, .warning, "tailAlphaOutOfRange",
                            "Ribbon tail alpha should be between 0 and 1."))
    }
    return issues
}

private func validateSubEmitters(_ settings: ParticleSubEmittersModule,
                                 moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.legacyTrigger != .none && settings.legacyBurstCount <= 0 {
        issues.append(issue(moduleID, .warning, "legacySubEmitterNoBurst",
                            "Legacy sub-emitter trigger is active but burst count is zero."))
    }
    if settings.legacyProbability < 0 || settings.legacyProbability > 1 {
        issues.append(issue(moduleID, .warning, "legacyProbabilityOutOfRange",
                            "Legacy sub-emitter probability should be between 0 and 1."))
    }
    for (index, rule) in settings.rules.enumerated() {
        if rule.trigger != .none && rule.burstCount <= 0 {
            issues.append(issue(moduleID, .warning, "subEmitterNoBurst",
                                "Sub-emitter rule \(index + 1) has a trigger but no burst count."))
        }
        if rule.probability < 0 || rule.probability > 1 {
            issues.append(issue(moduleID, .warning, "subEmitterProbabilityOutOfRange",
                                "Sub-emitter rule \(index + 1) probability should be between 0 and 1."))
        }
        if rule.lifetime <= 0 {
            issues.append(issue(moduleID, .error, "subEmitterInvalidLifetime",
                                "Sub-emitter rule \(index + 1) lifetime must be greater than zero."))
        }
    }
    return issues
}

private func validateGPUSimulation(_ settings: ParticleGPUSimulationModule,
                                   moduleID: String) -> [ParticleModuleIssue] {
    var issues: [ParticleModuleIssue] = []
    if settings.workgroupSize <= 0 {
        issues.append(issue(moduleID, .error, "invalidGPUWorkgroup",
                            "GPU workgroup size must be greater than zero."))
    } else if settings.workgroupSize > ParticleGPUSimulationPlan.maximumWorkgroupSize {
        issues.append(issue(moduleID, .warning, "gpuWorkgroupClamped",
                            "GPU workgroup size exceeds the runtime maximum and will be clamped."))
    }
    return issues
}

private func issue(_ moduleID: String,
                   _ severity: ParticleModuleIssueSeverity,
                   _ code: String,
                   _ message: String) -> ParticleModuleIssue {
    ParticleModuleIssue(moduleID: moduleID,
                        severity: severity,
                        code: code,
                        message: message)
}

public extension ParticleEmitter {
    var moduleStack: ParticleModuleStack {
        ParticleModuleStack(emitter: self, preserving: authoredModuleStack)
    }

    mutating func apply(_ moduleStack: ParticleModuleStack) {
        for module in moduleStack.modules where module.isEnabled {
            switch module.settings {
            case let .emission(settings):
                isEmitting = settings.isEmitting
                looping = settings.looping
                duration = max(0, settings.duration)
                prewarmTime = max(0, settings.prewarmTime)
                prewarmStep = max(1.0 / 240.0, settings.prewarmStep)
                emissionRate = max(0, settings.emissionRate)
                emissionRateCurve = settings.emissionRateCurve
                distanceEmissionRate = max(0, settings.distanceEmissionRate)
                distanceEmissionRateCurve = settings.distanceEmissionRateCurve
                burstCount = max(0, settings.burstCount)
                burstInterval = max(0, settings.burstInterval)
                maxParticles = max(0, settings.maxParticles)
                maxRenderedParticles = max(0, settings.maxRenderedParticles)
            case let .shape(settings):
                originOffset = settings.originOffset
                spawnRadius = max(0, settings.spawnRadius)
                emissionShape = settings.emissionShape
                boxHalfExtents = SIMD3<Float>(
                    max(0, settings.boxHalfExtents.x),
                    max(0, settings.boxHalfExtents.y),
                    max(0, settings.boxHalfExtents.z)
                )
                coneRadius = max(0, settings.coneRadius)
                coneHeight = max(0, settings.coneHeight)
            case let .velocity(settings):
                startVelocity = settings.startVelocity
                velocityRandomness = settings.velocityRandomness
                velocityInheritance = max(0, settings.velocityInheritance)
            case let .forces(settings):
                gravity = settings.gravity
                noiseStrength = max(0, settings.noiseStrength)
                noiseScale = max(0.0001, settings.noiseScale)
                noiseSpeed = max(0, settings.noiseSpeed)
                forceMode = settings.forceMode
                forceCenter = settings.forceCenter
                forceAxis = settings.forceAxis
                forceRadius = max(0, settings.forceRadius)
                forceStrength = settings.forceStrength
                forceFalloff = max(0, settings.forceFalloff)
                vectorFieldMode = settings.vectorFieldMode
                vectorFieldDirection = settings.vectorFieldDirection
                vectorFieldStrength = settings.vectorFieldStrength
                vectorFieldScale = max(0.0001, settings.vectorFieldScale)
                vectorFieldScrollSpeed = max(0, settings.vectorFieldScrollSpeed)
            case let .collision(settings):
                collisionMode = settings.collisionMode
                collisionPlaneY = settings.collisionPlaneY
                collisionRestitution = simd_clamp(settings.collisionRestitution, 0, 1)
                collisionDamping = simd_clamp(settings.collisionDamping, 0, 1)
            case let .appearance(settings):
                lifetime = max(0, settings.lifetime)
                lifetimeRandomness = max(0, settings.lifetimeRandomness)
                startSize = settings.startSize
                endSize = settings.endSize
                sizeRandomness = max(0, settings.sizeRandomness)
                startRotation = settings.startRotation
                rotationRandomness = max(0, settings.rotationRandomness)
                angularVelocity = settings.angularVelocity
                angularVelocityRandomness = max(0, settings.angularVelocityRandomness)
                sizeCurve = settings.sizeCurve
                startColor = settings.startColor
                endColor = settings.endColor
                colorCurve = settings.colorCurve
                blendMode = settings.blendMode
            case let .textureSheet(settings):
                textureAssetID = settings.textureAssetID?.isEmpty == true ? nil : settings.textureAssetID
                texturePath = settings.texturePath?.isEmpty == true ? nil : settings.texturePath
                textureSheetColumns = max(1, settings.columns)
                textureSheetRows = max(1, settings.rows)
                textureSheetFrameCount = max(1, settings.frameCount)
                textureSheetFrameRate = max(0, settings.frameRate)
                textureSheetPlaybackMode = settings.playbackMode
                textureSheetStartFrame = max(0, settings.startFrame)
                textureSheetFrameRandomness = max(0, settings.frameRandomness)
            case let .renderer(settings):
                renderMode = settings.renderMode
                sortMode = settings.sortMode
                renderAlignment = settings.renderAlignment
                velocityStretchScale = max(0, settings.velocityStretchScale)
                velocityStretchMax = max(1, settings.velocityStretchMax)
                maxRenderDistance = max(0, settings.maxRenderDistance)
                renderDistanceFadeRange = max(0, settings.renderDistanceFadeRange)
                renderLODStartDistance = max(0, settings.renderLODStartDistance)
                renderLODEndDistance = max(0, settings.renderLODEndDistance)
                renderLODMinParticleScale = simd_clamp(settings.renderLODMinParticleScale, 0, 1)
                renderBoundsMode = settings.renderBoundsMode
                renderBoundsRadius = max(0, settings.renderBoundsRadius)
            case let .trails(settings):
                ribbonWidthScale = max(0, settings.ribbonWidthScale)
                ribbonTailWidthScale = max(0, settings.ribbonTailWidthScale)
                ribbonTailAlphaScale = simd_clamp(settings.ribbonTailAlphaScale, 0, 1)
                ribbonMaxSegmentLength = max(0, settings.ribbonMaxSegmentLength)
                ribbonJoinOverlapScale = max(0, settings.ribbonJoinOverlapScale)
                ribbonSmoothingSegments = min(16, max(1, settings.ribbonSmoothingSegments))
                ribbonTextureTiling = max(0, settings.ribbonTextureTiling)
                ribbonTextureOffset = settings.ribbonTextureOffset
                trailLength = max(0, settings.trailLength)
                trailSegments = max(0, settings.trailSegments)
                trailEndSizeScale = max(0, settings.trailEndSizeScale)
                trailEndAlphaScale = simd_clamp(settings.trailEndAlphaScale, 0, 1)
            case let .subEmitters(settings):
                subEmitterTrigger = settings.legacyTrigger
                subEmitterBurstCount = max(0, settings.legacyBurstCount)
                subEmitterProbability = simd_clamp(settings.legacyProbability, 0, 1)
                subEmitterMaxDepth = max(0, settings.legacyMaxDepth)
                subEmitterInheritVelocity = max(0, settings.legacyInheritVelocity)
                subEmitterLifetime = max(0.0001, settings.legacyLifetime)
                subEmitterStartVelocity = settings.legacyStartVelocity
                subEmitterVelocityRandomness = settings.legacyVelocityRandomness
                subEmitterStartSize = max(0, settings.legacyStartSize)
                subEmitterEndSize = max(0, settings.legacyEndSize)
                subEmitterStartColor = settings.legacyStartColor
                subEmitterEndColor = settings.legacyEndColor
                subEmitters = settings.rules.map {
                    ParticleSubEmitter(trigger: $0.trigger,
                                       burstCount: $0.burstCount,
                                       probability: $0.probability,
                                       maxDepth: $0.maxDepth,
                                       inheritVelocity: $0.inheritVelocity,
                                       lifetime: $0.lifetime,
                                       startVelocity: $0.startVelocity,
                                       velocityRandomness: $0.velocityRandomness,
                                       startSize: $0.startSize,
                                       endSize: $0.endSize,
                                       startColor: $0.startColor,
                                       endColor: $0.endColor)
                }
            case let .gpuSimulation(settings):
                simulationSpace = settings.simulationSpace
                simulationBackend = settings.simulationBackend
                gpuSimulationWorkgroupSize = max(1, settings.workgroupSize)
            }
        }
        authoredModuleStack = ParticleModuleStack(emitter: self, preserving: moduleStack)
    }
}
