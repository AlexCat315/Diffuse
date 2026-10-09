import SceneRuntime

extension GPUParticleSimulationEventTrigger {
    public var particleSubEmitterTrigger: ParticleSubEmitterTrigger? {
        switch self {
        case .collision:
            return .collision
        case .death:
            return .death
        case .unknown:
            return nil
        }
    }
}

extension GPUParticleSimulationEventRecord {
    public func makeParticleEvent() -> ParticleEvent? {
        guard let trigger = trigger.particleSubEmitterTrigger else { return nil }
        return ParticleEvent(trigger: trigger,
                             position: position,
                             velocity: velocity,
                             age: age,
                             lifetime: lifetime,
                             generation: generation,
                             appearanceIndex: appearanceIndex)
    }
}

extension GPUParticleSimulationEventSnapshot {
    public func makeParticleEvents() -> [ParticleEvent] {
        records.compactMap { $0.makeParticleEvent() }
    }
}
