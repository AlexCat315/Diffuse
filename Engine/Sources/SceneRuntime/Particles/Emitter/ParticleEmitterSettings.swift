import SIMDCompat

/// Authored particle settings, grouped by the feature that owns their defaults and validation.
public struct ParticleEmitterSettings: Codable, Sendable, Equatable {
    public var emission = ParticleEmissionModule()
    public var shape = ParticleShapeModule()
    public var velocity = ParticleVelocityModule()
    public var forces = ParticleForcesModule()
    public var collision = ParticleCollisionModule()
    public var appearance = ParticleAppearanceModule()
    public var textureSheet = ParticleTextureSheetModule()
    public var renderer = ParticleRendererModule()
    public var trails = ParticleTrailsModule()
    public var subEmitters = ParticleSubEmittersModule()
    public var gpuSimulation = ParticleGPUSimulationModule()

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case emission, shape, velocity, forces, collision, appearance
        case textureSheet, renderer, trails, subEmitters, gpuSimulation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emission = try container.decodeIfPresent(ParticleEmissionModule.self, forKey: .emission) ?? emission
        shape = try container.decodeIfPresent(ParticleShapeModule.self, forKey: .shape) ?? shape
        velocity = try container.decodeIfPresent(ParticleVelocityModule.self, forKey: .velocity) ?? velocity
        forces = try container.decodeIfPresent(ParticleForcesModule.self, forKey: .forces) ?? forces
        collision = try container.decodeIfPresent(ParticleCollisionModule.self, forKey: .collision) ?? collision
        appearance = try container.decodeIfPresent(ParticleAppearanceModule.self, forKey: .appearance) ?? appearance
        textureSheet =
            try container.decodeIfPresent(ParticleTextureSheetModule.self, forKey: .textureSheet) ?? textureSheet
        renderer = try container.decodeIfPresent(ParticleRendererModule.self, forKey: .renderer) ?? renderer
        trails = try container.decodeIfPresent(ParticleTrailsModule.self, forKey: .trails) ?? trails
        subEmitters = try container.decodeIfPresent(ParticleSubEmittersModule.self, forKey: .subEmitters) ?? subEmitters
        gpuSimulation =
            try container.decodeIfPresent(ParticleGPUSimulationModule.self, forKey: .gpuSimulation) ?? gpuSimulation
    }

    mutating func normalize() {
        emission.normalize()
        shape.normalize()
        velocity.normalize()
        forces.normalize()
        collision.normalize()
        appearance.normalize()
        textureSheet.normalize()
        renderer.normalize()
        trails.normalize()
        subEmitters.normalize()
        gpuSimulation.normalize()
    }
}
