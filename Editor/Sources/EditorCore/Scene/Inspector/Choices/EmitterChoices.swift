import SceneRuntime

extension ParticleEmissionShape: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .sphere: return L("Sphere")
        case .box: return L("Box")
        case .cone: return L("Cone")
        }
    }
}

extension ParticleCollisionMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .none: return L("None")
        case .localPlane: return L("Local Plane")
        case .worldPlane: return L("World Plane")
        }
    }
}

extension ParticleSimulationSpace: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .local: return L("Local")
        case .world: return L("World")
        }
    }
}

extension ParticleSimulationBackend: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .cpu: return L("CPU")
        case .gpuIfSupported: return L("GPU Preferred")
        case .gpuRequired: return L("GPU Required")
        }
    }
}

extension ParticleBlendMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .alpha: return L("Alpha")
        case .additive: return L("Additive")
        }
    }
}

extension ParticleRenderMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .billboard: return L("Billboard")
        case .ribbon: return L("Ribbon")
        }
    }
}

extension ParticleSortMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .distanceDescending: return L("Back to Front")
        case .distanceAscending: return L("Front to Back")
        case .oldestFirst: return L("Oldest First")
        case .youngestFirst: return L("Youngest First")
        }
    }
}

extension ParticleTextureSheetPlaybackMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .automatic: return L("Auto")
        case .lifetime: return L("Lifetime")
        case .playOnce: return L("Play Once")
        case .loop: return L("Loop")
        case .singleFrame: return L("Single Frame")
        }
    }
}

extension ParticleRenderAlignment: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .billboard: return L("Billboard")
        case .velocity: return L("Velocity")
        }
    }
}

extension ParticleRenderBoundsMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .disabled: return L("Disabled")
        case .manual: return L("Manual")
        case .automatic: return L("Automatic")
        }
    }
}

extension ParticleForceMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .none: return L("None")
        case .radial: return L("Radial")
        case .vortex: return L("Vortex")
        }
    }
}

extension ParticleVectorFieldMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .none: return L("None")
        case .uniform: return L("Uniform")
        case .curl: return L("Curl")
        }
    }
}

extension ParticleSubEmitterTrigger: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .none: return L("None")
        case .death: return L("Death")
        case .collision: return L("Collision")
        }
    }
}
