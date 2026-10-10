import SceneRuntime

extension PhysicsSimulationMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .off: return L("Off")
        case .preview: return L("Preview")
        case .play: return L("Play")
        case .bake: return L("Bake")
        }
    }
}

extension VehicleControllerKind: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .wheeled: return L("Wheeled")
        case .tracked: return L("Tracked")
        case .motorcycle: return L("Motorcycle")
        }
    }
}

extension ColliderShapeKind: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .box: return L("Box")
        case .sphere: return L("Sphere")
        case .capsule: return L("Capsule")
        case .cylinder: return L("Cylinder")
        case .heightField: return L("Height Field")
        case .mesh: return L("Mesh")
        case .convex: return L("Convex")
        }
    }
}

extension PhysicsJointKind: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .pointToPoint: return L("Point")
        case .fixed: return L("Fixed")
        case .distance: return L("Distance")
        case .hinge: return L("Hinge")
        case .slider: return L("Slider")
        case .cone: return L("Cone / Swing Twist")
        case .sixDOF: return L("Six DOF")
        }
    }
}

extension PhysicsJointMotorMode: EditorInspectorEnumOption {
    public var inspectorOptionID: String { String(describing: self) }

    public var inspectorOptionLabel: String {
        switch self {
        case .disabled: return L("Disabled")
        case .position: return L("Position")
        case .velocity: return L("Velocity")
        }
    }
}
