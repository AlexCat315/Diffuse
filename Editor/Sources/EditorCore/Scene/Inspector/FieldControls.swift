import GuavaUIRuntime
import SceneRuntime

/// Identifies the control that renders a compound inspector field.
///
/// Generic values — text, numbers, choices, colors — render through the shared
/// control for their shape. Compound editors such as shape instance lists,
/// curves and module stacks carry an ID, so the property grid looks their control
/// up in a registry instead of switching on the value.
public struct EditorInspectorControlID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let colliderShapeInstances = Self(rawValue: "collider.shape-instances")
    public static let particleCurve = Self(rawValue: "particle.curve")
    public static let particleSubEmitters = Self(rawValue: "particle.sub-emitters")
    public static let particleModuleStack = Self(rawValue: "particle.module-stack")
    public static let entityReference = Self(rawValue: "entity.reference")
}

extension Binding {
    /// Erases the value type so a registered control can read and write it.
    /// Writes of another type are dropped: a mismatched registration must never
    /// corrupt the component document.
    public func erased() -> Binding<Any> {
        Binding<Any>(
            get: { wrappedValue },
            set: { next in
                guard let value = next as? Value else { return }
                wrappedValue = value
            })
    }
}

public extension EditorInspectorFieldValue {
    /// The registered control that renders this value, if it owns one.
    var controlID: EditorInspectorControlID? {
        switch self {
        case .colliderShapeInstances: return .colliderShapeInstances
        case .particleCurve: return .particleCurve
        case .particleSubEmitters: return .particleSubEmitters
        case .particleModuleStack: return .particleModuleStack
        case .entityReference: return .entityReference
        default: return nil
        }
    }

    var erasedBinding: Binding<Any>? {
        switch self {
        case let .colliderShapeInstances(binding): return binding.erased()
        case let .particleCurve(binding): return binding.erased()
        case let .particleSubEmitters(binding): return binding.erased()
        case let .particleModuleStack(binding): return binding.erased()
        case let .entityReference(binding, _): return binding.erased()
        default: return nil
        }
    }

    /// Entity choices travel with the value, so a control can render names without
    /// knowing which component produced the field.
    var entityOptions: [EditorInspectorEntityOption]? {
        if case let .entityReference(_, options) = self { return options }
        return nil
    }
}
