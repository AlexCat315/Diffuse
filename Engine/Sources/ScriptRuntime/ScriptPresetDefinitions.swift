import SIMDCompat

public extension ScriptPresetKind {
    var definition: ScriptDefinition {
        let target: [ScriptProperty] = [
            ScriptProperty("targetEntityID", label: "Target", defaultValue: .entity(0)),
            ScriptProperty("targetEntityName", label: "Target Name", defaultValue: .string("")),
        ]
        let properties: [ScriptProperty]
        switch self {
        case .rotator:
            properties = [ScriptProperty("speed", label: "Angular Speed", defaultValue: .vector3(SIMD3(0, 1.57, 0)))]
        case .oscillator:
            properties = [
                ScriptProperty("axis", label: "Axis", defaultValue: .vector3(SIMD3(0, 1, 0))),
                ScriptProperty("amplitude", label: "Amplitude", defaultValue: .number(1), minimum: 0),
                ScriptProperty("frequency", label: "Frequency", defaultValue: .number(1), minimum: 0),
            ]
        case .mover:
            properties = [ScriptProperty("velocity", label: "Velocity", defaultValue: .vector3(.zero))]
        case .destroyAfter:
            properties = [ScriptProperty("seconds", label: "Lifetime", defaultValue: .number(1), minimum: 0)]
        case .follower:
            properties = target + [
                ScriptProperty("speed", label: "Move Speed", defaultValue: .number(5), minimum: 0),
                ScriptProperty("arrivalRadius", label: "Arrival Radius", defaultValue: .number(0.1), minimum: 0),
            ]
        case .lookAt:
            properties = target
        case .characterController:
            properties = [
                ScriptProperty("moveSpeed", label: "Move Speed", defaultValue: .number(5), minimum: 0),
                ScriptProperty("jumpSpeed", label: "Jump Speed", defaultValue: .number(8), minimum: 0),
                ScriptProperty("crouchAction", label: "Crouch Action", defaultValue: .string("crouch")),
            ]
        case .firstPersonCamera:
            properties = [
                ScriptProperty("moveSpeed", label: "Move Speed", defaultValue: .number(5), minimum: 0),
                ScriptProperty("lookSensitivity", label: "Look Sensitivity", defaultValue: .number(0.002), minimum: 0),
            ]
        case .orbitCamera:
            properties = [
                ScriptProperty("target", label: "Target Position", defaultValue: .vector3(.zero)),
                ScriptProperty("distance", label: "Distance", defaultValue: .number(10), minimum: 0),
                ScriptProperty("orbitSpeed", label: "Orbit Speed", defaultValue: .number(0.005)),
                ScriptProperty("zoomSpeed", label: "Zoom Speed", defaultValue: .number(1), minimum: 0),
                ScriptProperty("minDistance", label: "Min Distance", defaultValue: .number(1), minimum: 0),
                ScriptProperty("maxDistance", label: "Max Distance", defaultValue: .number(100), minimum: 0),
            ]
        }
        return ScriptDefinition(properties: properties)
    }
}
