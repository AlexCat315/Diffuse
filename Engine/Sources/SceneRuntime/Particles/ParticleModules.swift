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
                                  settings: .emission(emitter.settings.emission)),
            ParticleEmitterModule(id: "shape",
                                  stage: .spawn,
                                  displayName: "Shape",
                                  settings: .shape(emitter.settings.shape)),
            ParticleEmitterModule(id: "velocity",
                                  stage: .initialize,
                                  displayName: "Velocity",
                                  settings: .velocity(emitter.settings.velocity)),
            ParticleEmitterModule(id: "forces",
                                  stage: .update,
                                  displayName: "Forces",
                                  settings: .forces(emitter.settings.forces)),
            ParticleEmitterModule(id: "collision",
                                  stage: .update,
                                  displayName: "Collision",
                                  settings: .collision(emitter.settings.collision)),
            ParticleEmitterModule(id: "appearance",
                                  stage: .initialize,
                                  displayName: "Appearance",
                                  settings: .appearance(emitter.settings.appearance)),
            ParticleEmitterModule(id: "textureSheet",
                                  stage: .render,
                                  displayName: "Texture Sheet",
                                  settings: .textureSheet(emitter.settings.textureSheet)),
            ParticleEmitterModule(id: "renderer",
                                  stage: .render,
                                  displayName: "Renderer",
                                  settings: .renderer(emitter.settings.renderer)),
            ParticleEmitterModule(id: "trails",
                                  stage: .render,
                                  displayName: "Trails",
                                  settings: .trails(emitter.settings.trails)),
            ParticleEmitterModule(id: "subEmitters",
                                  stage: .event,
                                  displayName: "Sub-Emitters",
                                  settings: .subEmitters(emitter.settings.subEmitters)),
            ParticleEmitterModule(id: "gpuSimulation",
                                  stage: .simulation,
                                  displayName: "GPU Simulation",
                                  settings: .gpuSimulation(emitter.settings.gpuSimulation)),
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

    public mutating func resetModuleSettings(for moduleID: String) {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }),
              var defaultModule = Self.defaultModule(for: moduleID) else {
            return
        }
        defaultModule.isEnabled = modules[index].isEnabled
        defaultModule.isExpanded = modules[index].isExpanded
        modules[index] = defaultModule
    }

    public func moduleSettingsDifferFromDefault(_ moduleID: String) -> Bool {
        guard let module = modules.first(where: { $0.id == moduleID }),
              var defaultModule = Self.defaultModule(for: moduleID) else {
            return false
        }
        defaultModule.isEnabled = module.isEnabled
        defaultModule.isExpanded = module.isExpanded
        return module != defaultModule
    }

    public var modifiedModuleIDs: [String] {
        modules.compactMap { module in
            moduleSettingsDifferFromDefault(module.id) ? module.id : nil
        }
    }

    public var expandedModuleIDs: [String] {
        modules.compactMap { $0.isExpanded ? $0.id : nil }
    }

    public mutating func collapseAllModules() {
        for index in modules.indices {
            modules[index].isExpanded = false
        }
    }

    public mutating func expandModules(withIDs moduleIDs: some Sequence<String>,
                                       collapseOthers: Bool = false) {
        let targetIDs = Set(moduleIDs)
        guard !targetIDs.isEmpty || collapseOthers else { return }
        for index in modules.indices {
            if targetIDs.contains(modules[index].id) {
                modules[index].isExpanded = true
            } else if collapseOthers {
                modules[index].isExpanded = false
            }
        }
    }

    public mutating func expandModifiedModules(collapseOthers: Bool = false) {
        expandModules(withIDs: modifiedModuleIDs, collapseOthers: collapseOthers)
    }

    @discardableResult
    public mutating func expandModulesWithValidationIssues(collapseOthers: Bool = false) -> [String] {
        let moduleIDs = validationIssues().map(\.moduleID)
        expandModules(withIDs: moduleIDs, collapseOthers: collapseOthers)
        return expandedModuleIDs
    }

    private static func defaultModule(for moduleID: String) -> ParticleEmitterModule? {
        ParticleModuleStack(emitter: ParticleEmitter()).modules.first { $0.id == moduleID }
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
    public var isEmitting: Bool = true
    public var looping: Bool = true
    public var duration: Float = 0
    public var simulationSpeed: Float = 1
    public var prewarmTime: Float = 0
    public var prewarmStep: Float = 1.0 / 30.0
    public var emissionRate: Float = 10
    public var emissionRateCurve: ParticleCurve = .constant(1)
    public var distanceEmissionRate: Float = 0
    public var distanceEmissionRateCurve: ParticleCurve = .constant(1)
    public var burstCount: Int = 0
    public var burstInterval: Float = 0
    public var maxParticles: Int = 256
    public var maxSpawnedParticlesPerFrame: Int = 0
    public var maxRenderedParticles: Int = 0
    public var seed: UInt64 = 0x9E3779B9

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case isEmitting
        case looping
        case duration
        case simulationSpeed
        case prewarmTime
        case prewarmStep
        case emissionRate
        case emissionRateCurve
        case distanceEmissionRate
        case distanceEmissionRateCurve
        case burstCount
        case burstInterval
        case maxParticles
        case maxSpawnedParticlesPerFrame
        case maxRenderedParticles
        case seed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEmitting = try container.decodeIfPresent(Bool.self, forKey: .isEmitting) ?? isEmitting
        looping = try container.decodeIfPresent(Bool.self, forKey: .looping) ?? looping
        duration = try container.decodeIfPresent(Float.self, forKey: .duration) ?? duration
        simulationSpeed = try container.decodeIfPresent(Float.self, forKey: .simulationSpeed) ?? simulationSpeed
        prewarmTime = try container.decodeIfPresent(Float.self, forKey: .prewarmTime) ?? prewarmTime
        prewarmStep = try container.decodeIfPresent(Float.self, forKey: .prewarmStep) ?? prewarmStep
        emissionRate = try container.decodeIfPresent(Float.self, forKey: .emissionRate) ?? emissionRate
        emissionRateCurve =
            try container.decodeIfPresent(ParticleCurve.self, forKey: .emissionRateCurve) ?? emissionRateCurve
        distanceEmissionRate =
            try container.decodeIfPresent(Float.self, forKey: .distanceEmissionRate) ?? distanceEmissionRate
        distanceEmissionRateCurve =
            try container.decodeIfPresent(ParticleCurve.self, forKey: .distanceEmissionRateCurve)
            ?? distanceEmissionRateCurve
        burstCount = try container.decodeIfPresent(Int.self, forKey: .burstCount) ?? burstCount
        burstInterval = try container.decodeIfPresent(Float.self, forKey: .burstInterval) ?? burstInterval
        maxParticles = try container.decodeIfPresent(Int.self, forKey: .maxParticles) ?? maxParticles
        maxSpawnedParticlesPerFrame =
            try container.decodeIfPresent(Int.self, forKey: .maxSpawnedParticlesPerFrame) ?? maxSpawnedParticlesPerFrame
        maxRenderedParticles =
            try container.decodeIfPresent(Int.self, forKey: .maxRenderedParticles) ?? maxRenderedParticles
        seed = try container.decodeIfPresent(UInt64.self, forKey: .seed) ?? seed
    }

    mutating func normalize() {
        duration = max(0, duration)
        simulationSpeed = max(0, simulationSpeed)
        prewarmTime = max(0, prewarmTime)
        prewarmStep = max(1.0 / 240.0, prewarmStep)
        emissionRate = max(0, emissionRate)
        distanceEmissionRate = max(0, distanceEmissionRate)
        burstCount = max(0, burstCount)
        burstInterval = max(0, burstInterval)
        maxParticles = max(0, maxParticles)
        maxSpawnedParticlesPerFrame = max(0, maxSpawnedParticlesPerFrame)
        maxRenderedParticles = max(0, maxRenderedParticles)
    }
}

public struct ParticleShapeModule: Codable, Sendable, Equatable {
    public var originOffset: SIMD3<Float> = .zero
    public var spawnRadius: Float = 0
    public var emissionShape: ParticleEmissionShape = .sphere
    public var boxHalfExtents: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5)
    public var coneRadius: Float = 0.5
    public var coneHeight: Float = 1

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case originOffset
        case spawnRadius
        case emissionShape
        case boxHalfExtents
        case coneRadius
        case coneHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        originOffset = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .originOffset) ?? originOffset
        spawnRadius = try container.decodeIfPresent(Float.self, forKey: .spawnRadius) ?? spawnRadius
        emissionShape =
            try container.decodeIfPresent(ParticleEmissionShape.self, forKey: .emissionShape) ?? emissionShape
        boxHalfExtents = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .boxHalfExtents) ?? boxHalfExtents
        coneRadius = try container.decodeIfPresent(Float.self, forKey: .coneRadius) ?? coneRadius
        coneHeight = try container.decodeIfPresent(Float.self, forKey: .coneHeight) ?? coneHeight
    }

    mutating func normalize() {
        spawnRadius = max(0, spawnRadius)
        boxHalfExtents = SIMD3<Float>(
            max(0, boxHalfExtents.x),
            max(0, boxHalfExtents.y),
            max(0, boxHalfExtents.z)
        )
        coneRadius = max(0, coneRadius)
        coneHeight = max(0, coneHeight)
    }
}

public struct ParticleVelocityModule: Codable, Sendable, Equatable {
    public var startVelocity: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    public var velocityRandomness: SIMD3<Float> = .zero
    public var velocityInheritance: Float = 0

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case startVelocity
        case velocityRandomness
        case velocityInheritance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startVelocity = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .startVelocity) ?? startVelocity
        velocityRandomness =
            try container.decodeIfPresent(SIMD3<Float>.self, forKey: .velocityRandomness) ?? velocityRandomness
        velocityInheritance =
            try container.decodeIfPresent(Float.self, forKey: .velocityInheritance) ?? velocityInheritance
    }

    mutating func normalize() {
        velocityInheritance = max(0, velocityInheritance)
    }
}

public struct ParticleForcesModule: Codable, Sendable, Equatable {
    public var gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0)
    public var noiseStrength: Float = 0
    public var noiseScale: Float = 1
    public var noiseSpeed: Float = 1
    public var forceMode: ParticleForceMode = .none
    public var forceCenter: SIMD3<Float> = .zero
    public var forceAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    public var forceRadius: Float = 0
    public var forceStrength: Float = 0
    public var forceFalloff: Float = 1
    public var vectorFieldMode: ParticleVectorFieldMode = .none
    public var vectorFieldDirection: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
    public var vectorFieldStrength: Float = 0
    public var vectorFieldScale: Float = 1
    public var vectorFieldScrollSpeed: Float = 0

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case gravity
        case noiseStrength
        case noiseScale
        case noiseSpeed
        case forceMode
        case forceCenter
        case forceAxis
        case forceRadius
        case forceStrength
        case forceFalloff
        case vectorFieldMode
        case vectorFieldDirection
        case vectorFieldStrength
        case vectorFieldScale
        case vectorFieldScrollSpeed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gravity = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .gravity) ?? gravity
        noiseStrength = try container.decodeIfPresent(Float.self, forKey: .noiseStrength) ?? noiseStrength
        noiseScale = try container.decodeIfPresent(Float.self, forKey: .noiseScale) ?? noiseScale
        noiseSpeed = try container.decodeIfPresent(Float.self, forKey: .noiseSpeed) ?? noiseSpeed
        forceMode = try container.decodeIfPresent(ParticleForceMode.self, forKey: .forceMode) ?? forceMode
        forceCenter = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .forceCenter) ?? forceCenter
        forceAxis = try container.decodeIfPresent(SIMD3<Float>.self, forKey: .forceAxis) ?? forceAxis
        forceRadius = try container.decodeIfPresent(Float.self, forKey: .forceRadius) ?? forceRadius
        forceStrength = try container.decodeIfPresent(Float.self, forKey: .forceStrength) ?? forceStrength
        forceFalloff = try container.decodeIfPresent(Float.self, forKey: .forceFalloff) ?? forceFalloff
        vectorFieldMode =
            try container.decodeIfPresent(ParticleVectorFieldMode.self, forKey: .vectorFieldMode) ?? vectorFieldMode
        vectorFieldDirection =
            try container.decodeIfPresent(SIMD3<Float>.self, forKey: .vectorFieldDirection) ?? vectorFieldDirection
        vectorFieldStrength =
            try container.decodeIfPresent(Float.self, forKey: .vectorFieldStrength) ?? vectorFieldStrength
        vectorFieldScale = try container.decodeIfPresent(Float.self, forKey: .vectorFieldScale) ?? vectorFieldScale
        vectorFieldScrollSpeed =
            try container.decodeIfPresent(Float.self, forKey: .vectorFieldScrollSpeed) ?? vectorFieldScrollSpeed
    }

    mutating func normalize() {
        noiseStrength = max(0, noiseStrength)
        noiseScale = max(0.0001, noiseScale)
        noiseSpeed = max(0, noiseSpeed)
        forceRadius = max(0, forceRadius)
        forceFalloff = max(0, forceFalloff)
        vectorFieldScale = max(0.0001, vectorFieldScale)
        vectorFieldScrollSpeed = max(0, vectorFieldScrollSpeed)
    }
}

public struct ParticleCollisionModule: Codable, Sendable, Equatable {
    public var collisionMode: ParticleCollisionMode = .none
    public var collisionPlaneY: Float = 0
    public var collisionRestitution: Float = 0.5
    public var collisionDamping: Float = 0

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case collisionMode
        case collisionPlaneY
        case collisionRestitution
        case collisionDamping
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collisionMode =
            try container.decodeIfPresent(ParticleCollisionMode.self, forKey: .collisionMode) ?? collisionMode
        collisionPlaneY = try container.decodeIfPresent(Float.self, forKey: .collisionPlaneY) ?? collisionPlaneY
        collisionRestitution =
            try container.decodeIfPresent(Float.self, forKey: .collisionRestitution) ?? collisionRestitution
        collisionDamping = try container.decodeIfPresent(Float.self, forKey: .collisionDamping) ?? collisionDamping
    }

    mutating func normalize() {
        collisionRestitution = simd_clamp(collisionRestitution, 0, 1)
        collisionDamping = simd_clamp(collisionDamping, 0, 1)
    }
}

public struct ParticleAppearanceModule: Codable, Sendable, Equatable {
    public var lifetime: Float = 2
    public var lifetimeRandomness: Float = 0
    public var startSize: Float = 1
    public var endSize: Float = 0
    public var sizeRandomness: Float = 0
    public var startRotation: Float = 0
    public var rotationRandomness: Float = 0
    public var angularVelocity: Float = 0
    public var angularVelocityRandomness: Float = 0
    public var sizeCurve: ParticleCurve = .linear
    public var startColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    public var endColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    public var colorCurve: ParticleCurve = .linear
    public var blendMode: ParticleBlendMode = .alpha

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case lifetime
        case lifetimeRandomness
        case startSize
        case endSize
        case sizeRandomness
        case startRotation
        case rotationRandomness
        case angularVelocity
        case angularVelocityRandomness
        case sizeCurve
        case startColor
        case endColor
        case colorCurve
        case blendMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lifetime = try container.decodeIfPresent(Float.self, forKey: .lifetime) ?? lifetime
        lifetimeRandomness =
            try container.decodeIfPresent(Float.self, forKey: .lifetimeRandomness) ?? lifetimeRandomness
        startSize = try container.decodeIfPresent(Float.self, forKey: .startSize) ?? startSize
        endSize = try container.decodeIfPresent(Float.self, forKey: .endSize) ?? endSize
        sizeRandomness = try container.decodeIfPresent(Float.self, forKey: .sizeRandomness) ?? sizeRandomness
        startRotation = try container.decodeIfPresent(Float.self, forKey: .startRotation) ?? startRotation
        rotationRandomness =
            try container.decodeIfPresent(Float.self, forKey: .rotationRandomness) ?? rotationRandomness
        angularVelocity = try container.decodeIfPresent(Float.self, forKey: .angularVelocity) ?? angularVelocity
        angularVelocityRandomness =
            try container.decodeIfPresent(Float.self, forKey: .angularVelocityRandomness) ?? angularVelocityRandomness
        sizeCurve = try container.decodeIfPresent(ParticleCurve.self, forKey: .sizeCurve) ?? sizeCurve
        startColor = try container.decodeIfPresent(SIMD4<Float>.self, forKey: .startColor) ?? startColor
        endColor = try container.decodeIfPresent(SIMD4<Float>.self, forKey: .endColor) ?? endColor
        colorCurve = try container.decodeIfPresent(ParticleCurve.self, forKey: .colorCurve) ?? colorCurve
        blendMode = try container.decodeIfPresent(ParticleBlendMode.self, forKey: .blendMode) ?? blendMode
    }

    mutating func normalize() {
        lifetime = max(0, lifetime)
        lifetimeRandomness = max(0, lifetimeRandomness)
        sizeRandomness = max(0, sizeRandomness)
        rotationRandomness = max(0, rotationRandomness)
        angularVelocityRandomness = max(0, angularVelocityRandomness)
    }
}

public struct ParticleTextureSheetModule: Codable, Sendable, Equatable {
    public var textureAssetID: String? = nil
    public var texturePath: String? = nil
    public var columns: Int = 1
    public var rows: Int = 1
    public var frameCount: Int = 1
    public var frameRate: Float = 0
    public var playbackMode: ParticleTextureSheetPlaybackMode = .automatic
    public var startFrame: Int = 0
    public var frameRandomness: Int = 0

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case textureAssetID
        case texturePath
        case columns
        case rows
        case frameCount
        case frameRate
        case playbackMode
        case startFrame
        case frameRandomness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textureAssetID = try container.decodeIfPresent(String.self, forKey: .textureAssetID)
        texturePath = try container.decodeIfPresent(String.self, forKey: .texturePath)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? columns
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? rows
        frameCount = try container.decodeIfPresent(Int.self, forKey: .frameCount) ?? frameCount
        frameRate = try container.decodeIfPresent(Float.self, forKey: .frameRate) ?? frameRate
        playbackMode =
            try container.decodeIfPresent(ParticleTextureSheetPlaybackMode.self, forKey: .playbackMode) ?? playbackMode
        startFrame = try container.decodeIfPresent(Int.self, forKey: .startFrame) ?? startFrame
        frameRandomness = try container.decodeIfPresent(Int.self, forKey: .frameRandomness) ?? frameRandomness
    }

    mutating func normalize() {
        textureAssetID = textureAssetID?.isEmpty == true ? nil : textureAssetID
        texturePath = texturePath?.isEmpty == true ? nil : texturePath
        columns = max(1, columns)
        rows = max(1, rows)
        frameCount = max(1, frameCount)
        frameRate = max(0, frameRate)
        startFrame = max(0, startFrame)
        frameRandomness = max(0, frameRandomness)
    }
}

public struct ParticleRendererModule: Codable, Sendable, Equatable {
    public var renderMode: ParticleRenderMode = .billboard
    public var sortMode: ParticleSortMode = .distanceDescending
    public var renderSortPriority: Int = 0
    public var renderAlignment: ParticleRenderAlignment = .billboard
    public var velocityStretchScale: Float = 0
    public var velocityStretchMax: Float = 8
    public var maxRenderDistance: Float = 0
    public var renderDistanceFadeRange: Float = 0
    public var renderLODStartDistance: Float = 0
    public var renderLODEndDistance: Float = 0
    public var renderLODMinParticleScale: Float = 1
    public var renderBoundsMode: ParticleRenderBoundsMode = .disabled
    public var renderBoundsRadius: Float = 0

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case renderMode
        case sortMode
        case renderSortPriority
        case renderAlignment
        case velocityStretchScale
        case velocityStretchMax
        case maxRenderDistance
        case renderDistanceFadeRange
        case renderLODStartDistance
        case renderLODEndDistance
        case renderLODMinParticleScale
        case renderBoundsMode
        case renderBoundsRadius
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        renderMode = try container.decodeIfPresent(ParticleRenderMode.self, forKey: .renderMode) ?? renderMode
        sortMode = try container.decodeIfPresent(ParticleSortMode.self, forKey: .sortMode) ?? sortMode
        renderSortPriority = try container.decodeIfPresent(Int.self, forKey: .renderSortPriority) ?? renderSortPriority
        renderAlignment =
            try container.decodeIfPresent(ParticleRenderAlignment.self, forKey: .renderAlignment) ?? renderAlignment
        velocityStretchScale =
            try container.decodeIfPresent(Float.self, forKey: .velocityStretchScale) ?? velocityStretchScale
        velocityStretchMax =
            try container.decodeIfPresent(Float.self, forKey: .velocityStretchMax) ?? velocityStretchMax
        maxRenderDistance = try container.decodeIfPresent(Float.self, forKey: .maxRenderDistance) ?? maxRenderDistance
        renderDistanceFadeRange =
            try container.decodeIfPresent(Float.self, forKey: .renderDistanceFadeRange) ?? renderDistanceFadeRange
        renderLODStartDistance =
            try container.decodeIfPresent(Float.self, forKey: .renderLODStartDistance) ?? renderLODStartDistance
        renderLODEndDistance =
            try container.decodeIfPresent(Float.self, forKey: .renderLODEndDistance) ?? renderLODEndDistance
        renderLODMinParticleScale =
            try container.decodeIfPresent(Float.self, forKey: .renderLODMinParticleScale) ?? renderLODMinParticleScale
        renderBoundsMode =
            try container.decodeIfPresent(ParticleRenderBoundsMode.self, forKey: .renderBoundsMode) ?? renderBoundsMode
        renderBoundsRadius =
            try container.decodeIfPresent(Float.self, forKey: .renderBoundsRadius) ?? renderBoundsRadius
    }

    mutating func normalize() {
        velocityStretchScale = max(0, velocityStretchScale)
        velocityStretchMax = max(1, velocityStretchMax)
        maxRenderDistance = max(0, maxRenderDistance)
        renderDistanceFadeRange = max(0, renderDistanceFadeRange)
        renderLODStartDistance = max(0, renderLODStartDistance)
        renderLODEndDistance = max(0, renderLODEndDistance)
        renderLODMinParticleScale = simd_clamp(renderLODMinParticleScale, 0, 1)
        renderBoundsRadius = max(0, renderBoundsRadius)
    }
}

public struct ParticleTrailsModule: Codable, Sendable, Equatable {
    public var ribbonWidthScale: Float = 1
    public var ribbonTailWidthScale: Float = 1
    public var ribbonTailAlphaScale: Float = 1
    public var ribbonMaxSegmentLength: Float = 0
    public var ribbonJoinOverlapScale: Float = 0
    public var ribbonSmoothingSegments: Int = 1
    public var ribbonTextureTiling: Float = 0
    public var ribbonTextureOffset: Float = 0
    public var trailLength: Float = 0
    public var trailSegments: Int = 0
    public var trailEndSizeScale: Float = 0.5
    public var trailEndAlphaScale: Float = 0

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case ribbonWidthScale
        case ribbonTailWidthScale
        case ribbonTailAlphaScale
        case ribbonMaxSegmentLength
        case ribbonJoinOverlapScale
        case ribbonSmoothingSegments
        case ribbonTextureTiling
        case ribbonTextureOffset
        case trailLength
        case trailSegments
        case trailEndSizeScale
        case trailEndAlphaScale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ribbonWidthScale = try container.decodeIfPresent(Float.self, forKey: .ribbonWidthScale) ?? ribbonWidthScale
        ribbonTailWidthScale =
            try container.decodeIfPresent(Float.self, forKey: .ribbonTailWidthScale) ?? ribbonTailWidthScale
        ribbonTailAlphaScale =
            try container.decodeIfPresent(Float.self, forKey: .ribbonTailAlphaScale) ?? ribbonTailAlphaScale
        ribbonMaxSegmentLength =
            try container.decodeIfPresent(Float.self, forKey: .ribbonMaxSegmentLength) ?? ribbonMaxSegmentLength
        ribbonJoinOverlapScale =
            try container.decodeIfPresent(Float.self, forKey: .ribbonJoinOverlapScale) ?? ribbonJoinOverlapScale
        ribbonSmoothingSegments =
            try container.decodeIfPresent(Int.self, forKey: .ribbonSmoothingSegments) ?? ribbonSmoothingSegments
        ribbonTextureTiling =
            try container.decodeIfPresent(Float.self, forKey: .ribbonTextureTiling) ?? ribbonTextureTiling
        ribbonTextureOffset =
            try container.decodeIfPresent(Float.self, forKey: .ribbonTextureOffset) ?? ribbonTextureOffset
        trailLength = try container.decodeIfPresent(Float.self, forKey: .trailLength) ?? trailLength
        trailSegments = try container.decodeIfPresent(Int.self, forKey: .trailSegments) ?? trailSegments
        trailEndSizeScale = try container.decodeIfPresent(Float.self, forKey: .trailEndSizeScale) ?? trailEndSizeScale
        trailEndAlphaScale =
            try container.decodeIfPresent(Float.self, forKey: .trailEndAlphaScale) ?? trailEndAlphaScale
    }

    mutating func normalize() {
        ribbonWidthScale = max(0, ribbonWidthScale)
        ribbonTailWidthScale = max(0, ribbonTailWidthScale)
        ribbonTailAlphaScale = simd_clamp(ribbonTailAlphaScale, 0, 1)
        ribbonMaxSegmentLength = max(0, ribbonMaxSegmentLength)
        ribbonJoinOverlapScale = max(0, ribbonJoinOverlapScale)
        ribbonSmoothingSegments = min(16, max(1, ribbonSmoothingSegments))
        ribbonTextureTiling = max(0, ribbonTextureTiling)
        trailLength = max(0, trailLength)
        trailSegments = max(0, trailSegments)
        trailEndSizeScale = max(0, trailEndSizeScale)
        trailEndAlphaScale = simd_clamp(trailEndAlphaScale, 0, 1)
    }
}

public struct ParticleSubEmittersModule: Codable, Sendable, Equatable {
    public var legacyTrigger: ParticleSubEmitterTrigger = .none
    public var legacyBurstCount: Int = 0
    public var legacyProbability: Float = 1
    public var legacyMaxDepth: Int = 1
    public var legacyInheritVelocity: Float = 0
    public var legacyLifetime: Float = 0.5
    public var legacyStartVelocity: SIMD3<Float> = .zero
    public var legacyVelocityRandomness: SIMD3<Float> = .zero
    public var legacyStartSize: Float = 0.25
    public var legacyEndSize: Float = 0
    public var legacyStartColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    public var legacyEndColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
    public var rules: [ParticleSubEmitter] = []

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case legacyTrigger
        case legacyBurstCount
        case legacyProbability
        case legacyMaxDepth
        case legacyInheritVelocity
        case legacyLifetime
        case legacyStartVelocity
        case legacyVelocityRandomness
        case legacyStartSize
        case legacyEndSize
        case legacyStartColor
        case legacyEndColor
        case rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        legacyTrigger =
            try container.decodeIfPresent(ParticleSubEmitterTrigger.self, forKey: .legacyTrigger) ?? legacyTrigger
        legacyBurstCount = try container.decodeIfPresent(Int.self, forKey: .legacyBurstCount) ?? legacyBurstCount
        legacyProbability = try container.decodeIfPresent(Float.self, forKey: .legacyProbability) ?? legacyProbability
        legacyMaxDepth = try container.decodeIfPresent(Int.self, forKey: .legacyMaxDepth) ?? legacyMaxDepth
        legacyInheritVelocity =
            try container.decodeIfPresent(Float.self, forKey: .legacyInheritVelocity) ?? legacyInheritVelocity
        legacyLifetime = try container.decodeIfPresent(Float.self, forKey: .legacyLifetime) ?? legacyLifetime
        legacyStartVelocity =
            try container.decodeIfPresent(SIMD3<Float>.self, forKey: .legacyStartVelocity) ?? legacyStartVelocity
        legacyVelocityRandomness =
            try container.decodeIfPresent(SIMD3<Float>.self, forKey: .legacyVelocityRandomness)
            ?? legacyVelocityRandomness
        legacyStartSize = try container.decodeIfPresent(Float.self, forKey: .legacyStartSize) ?? legacyStartSize
        legacyEndSize = try container.decodeIfPresent(Float.self, forKey: .legacyEndSize) ?? legacyEndSize
        legacyStartColor =
            try container.decodeIfPresent(SIMD4<Float>.self, forKey: .legacyStartColor) ?? legacyStartColor
        legacyEndColor = try container.decodeIfPresent(SIMD4<Float>.self, forKey: .legacyEndColor) ?? legacyEndColor
        rules = try container.decodeIfPresent([ParticleSubEmitter].self, forKey: .rules) ?? rules
    }

    mutating func normalize() {
        legacyBurstCount = max(0, legacyBurstCount)
        legacyProbability = simd_clamp(legacyProbability, 0, 1)
        legacyMaxDepth = max(0, legacyMaxDepth)
        legacyInheritVelocity = max(0, legacyInheritVelocity)
        legacyLifetime = max(0.0001, legacyLifetime)
        legacyStartSize = max(0, legacyStartSize)
        legacyEndSize = max(0, legacyEndSize)
        rules = rules.map {
            ParticleSubEmitter(
                trigger: $0.trigger,
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
    }
}

public struct ParticleGPUSimulationModule: Codable, Sendable, Equatable {
    public var simulationSpace: ParticleSimulationSpace = .local
    public var simulationBackend: ParticleSimulationBackend = .cpu
    public var workgroupSize: Int = 64

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case simulationSpace
        case simulationBackend
        case workgroupSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        simulationSpace =
            try container.decodeIfPresent(ParticleSimulationSpace.self, forKey: .simulationSpace) ?? simulationSpace
        simulationBackend =
            try container.decodeIfPresent(ParticleSimulationBackend.self, forKey: .simulationBackend)
            ?? simulationBackend
        workgroupSize = try container.decodeIfPresent(Int.self, forKey: .workgroupSize) ?? workgroupSize
    }

    mutating func normalize() {
        workgroupSize = max(1, workgroupSize)
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
        repairModuleTopology()
        for index in modules.indices where modules[index].isEnabled {
            modules[index].settings.repairValidationIssues()
        }
    }

    mutating func repairValidationIssues(for moduleID: String) {
        repairModuleTopology()
        guard let index = modules.firstIndex(where: { $0.id == moduleID && $0.isEnabled }) else {
            return
        }
        modules[index].settings.repairValidationIssues()
    }

    private mutating func repairModuleTopology() {
        let defaultModules = ParticleModuleStack(emitter: ParticleEmitter()).modules
        let defaultsByID = Dictionary(uniqueKeysWithValues: defaultModules.map { ($0.id, $0) })
        let defaultIDs = Set(Self.defaultModuleIDs)
        var seenIDs: Set<String> = []
        var repaired: [ParticleEmitterModule] = []
        repaired.reserveCapacity(max(modules.count, defaultModules.count))

        for module in modules {
            guard seenIDs.insert(module.id).inserted else { continue }
            var normalized = module
            if defaultIDs.contains(module.id), let defaultModule = defaultsByID[module.id] {
                normalized.stage = defaultModule.stage
                normalized.displayName = defaultModule.displayName
            }
            repaired.append(normalized)
        }

        for defaultModule in defaultModules where !seenIDs.contains(defaultModule.id) {
            repaired.append(defaultModule)
            seenIDs.insert(defaultModule.id)
        }

        version = Self.currentVersion
        modules = repaired
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
            settings.simulationSpeed = max(0, settings.simulationSpeed)
            settings.maxParticles = max(1, settings.maxParticles)
            settings.maxSpawnedParticlesPerFrame = max(0, settings.maxSpawnedParticlesPerFrame)
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
    if settings.simulationSpeed < 0 {
        issues.append(issue(moduleID, .warning, "negativeSimulationSpeed",
                            "Simulation speed is negative and will be clamped."))
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
    if settings.maxSpawnedParticlesPerFrame < 0 {
        issues.append(issue(moduleID, .warning, "negativeSpawnBudget",
                            "Max spawned particles per frame is negative and will be clamped."))
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
    if settings.velocityStretchScale < 0 {
        issues.append(issue(moduleID, .warning, "negativeVelocityStretch",
                            "Velocity stretch scale is negative and will be clamped."))
    }
    if settings.renderLODEndDistance > 0
        && settings.renderLODStartDistance > settings.renderLODEndDistance {
        issues.append(issue(moduleID, .warning, "invalidLODRange",
                            "LOD start distance should not exceed LOD end distance."))
    }
    if settings.renderLODStartDistance < 0 || settings.renderLODEndDistance < 0 {
        issues.append(issue(moduleID, .warning, "negativeLODDistance",
                            "LOD distances should not be negative."))
    }
    if settings.renderLODMinParticleScale < 0 || settings.renderLODMinParticleScale > 1 {
        issues.append(issue(moduleID, .warning, "lodScaleOutOfRange",
                            "LOD minimum particle scale should be between 0 and 1."))
    }
    if settings.maxRenderDistance < 0 {
        issues.append(issue(moduleID, .warning, "negativeMaxRenderDistance",
                            "Max render distance should not be negative."))
    }
    if settings.renderDistanceFadeRange < 0 {
        issues.append(issue(moduleID, .warning, "negativeFadeRange",
                            "Distance fade range should not be negative."))
    }
    if settings.maxRenderDistance > 0
        && settings.renderDistanceFadeRange > settings.maxRenderDistance {
        issues.append(issue(moduleID, .warning, "fadeRangeExceedsDistance",
                            "Distance fade range exceeds max render distance."))
    }
    if settings.renderBoundsRadius < 0 {
        issues.append(issue(moduleID, .warning, "negativeRenderBoundsRadius",
                            "Render bounds radius should not be negative."))
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
    if settings.trailLength < 0 || settings.trailSegments < 0 {
        issues.append(issue(moduleID, .warning, "negativeTrailSettings",
                            "Trail length and segment count should not be negative."))
    }
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
    if settings.ribbonWidthScale < 0 || settings.ribbonTailWidthScale < 0 {
        issues.append(issue(moduleID, .warning, "negativeRibbonWidth",
                            "Ribbon width scales should not be negative."))
    }
    if settings.ribbonMaxSegmentLength < 0 || settings.ribbonJoinOverlapScale < 0 {
        issues.append(issue(moduleID, .warning, "negativeRibbonSegment",
                            "Ribbon segment and join settings should not be negative."))
    }
    if settings.ribbonTextureTiling < 0 {
        issues.append(issue(moduleID, .warning, "negativeRibbonTiling",
                            "Ribbon texture tiling should not be negative."))
    }
    if settings.trailEndSizeScale < 0 {
        issues.append(issue(moduleID, .warning, "negativeTrailEndSize",
                            "Trail end size scale should not be negative."))
    }
    if settings.trailEndAlphaScale < 0 || settings.trailEndAlphaScale > 1 {
        issues.append(issue(moduleID, .warning, "trailEndAlphaOutOfRange",
                            "Trail end alpha should be between 0 and 1."))
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
            case let .emission(moduleSettings):
                if settings.emission.seed != moduleSettings.seed {
                    reseed(moduleSettings.seed)
                }
                settings.emission = moduleSettings
                settings.emission.normalize()
            case let .shape(moduleSettings):
                settings.shape = moduleSettings
                settings.shape.normalize()
            case let .velocity(moduleSettings):
                settings.velocity = moduleSettings
                settings.velocity.normalize()
            case let .forces(moduleSettings):
                settings.forces = moduleSettings
                settings.forces.normalize()
            case let .collision(moduleSettings):
                settings.collision = moduleSettings
                settings.collision.normalize()
            case let .appearance(moduleSettings):
                settings.appearance = moduleSettings
                settings.appearance.normalize()
            case let .textureSheet(moduleSettings):
                settings.textureSheet = moduleSettings
                settings.textureSheet.normalize()
            case let .renderer(moduleSettings):
                settings.renderer = moduleSettings
                settings.renderer.normalize()
            case let .trails(moduleSettings):
                settings.trails = moduleSettings
                settings.trails.normalize()
            case let .subEmitters(moduleSettings):
                settings.subEmitters = moduleSettings
                settings.subEmitters.normalize()
            case let .gpuSimulation(moduleSettings):
                settings.gpuSimulation = moduleSettings
                settings.gpuSimulation.normalize()
            }
        }
        authoredModuleStack = moduleStack
    }
}
