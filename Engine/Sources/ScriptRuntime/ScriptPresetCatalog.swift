import SceneRuntime
import SIMDCompat

/// Presets that can be referenced by project script manifests. The preset name is
/// stable across Editor and Player processes; a `ScriptHandle` is not.
public enum ScriptPresetKind: String, CaseIterable, Codable, Sendable {
    case rotator
    case oscillator
    case mover
    case destroyAfter = "destroy-after"
    case follower
    case lookAt = "look-at"
    case characterController = "character-controller"
    case firstPersonCamera = "first-person-camera"
    case orbitCamera = "orbit-camera"
}

public extension ScriptRuntime {
    /// Registers or hot-replaces a named preset while preserving its process-local
    /// handle. Binding parameters override values from `defaultParametersJSON`.
    @discardableResult
    func registerPreset(_ preset: ScriptPresetKind,
                        named identifier: String,
                        defaultParametersJSON: String = "{}") -> ScriptHandle {
        register(named: identifier, defaultParametersJSON: defaultParametersJSON) {
            switch preset {
            case .rotator:
                return .rotator()
            case .oscillator:
                return .oscillator()
            case .mover:
                return .mover(velocity: .zero)
            case .destroyAfter:
                return .destroyAfter(1)
            case .follower:
                return .follower(target: EntityID(rawValue: 0))
            case .lookAt:
                return .lookAtTarget(EntityID(rawValue: 0))
            case .characterController:
                return .characterInputController()
            case .firstPersonCamera:
                return .firstPersonCamera()
            case .orbitCamera:
                return .orbitCamera()
            }
        }
    }
}
