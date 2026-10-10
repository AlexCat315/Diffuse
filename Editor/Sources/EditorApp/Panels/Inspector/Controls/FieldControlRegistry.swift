import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import SceneRuntime

enum EditorInspectorFieldControlError: Error, Equatable {
    case duplicateControl(EditorInspectorControlID)
}

/// Everything a registered control needs beyond the value itself.
struct EditorInspectorFieldControlContext {
    var identity: String
    var colliderState: InspectorColliderShapeEditorState
    var entityOptions: [EditorInspectorEntityOption]

    static var empty: Self {
        Self(identity: "", colliderState: InspectorColliderShapeEditorState(), entityOptions: [])
    }
}

/// How the property grid lays out a compound control's row.
struct EditorInspectorFieldMetrics {
    var layout: PropertyGridRowLayout
    var sizing: PropertyGridRowSizing
    var height: (Binding<Any>, Float) -> Float?
}

/// Compound inspector controls, keyed by `EditorInspectorControlID`.
///
/// The panel builds controls through this registry, so adding or replacing a
/// compound editor does not touch the field dispatcher. Registrations are values
/// and the built-in set is fixed at startup.
struct EditorInspectorFieldControlRegistry {
    typealias Control = (Binding<Any>, EditorInspectorFieldControlContext) -> AnyView

    private struct Registration {
        let control: Control
        let metrics: EditorInspectorFieldMetrics?
    }

    private var registrations: [EditorInspectorControlID: Registration] = [:]

    /// The app-wide control set. Controls are UI widgets, not session data, so
    /// they are built once instead of per panel.
    nonisolated(unsafe) static let builtIn: Self = {
        var registry = Self()
        // The built-in set is fixed: a duplicate ID is a programming error in the
        // registration files, not a runtime condition.
        try! registry.registerBuiltInControls()
        return registry
    }()

    init() {}

    var controlIDs: [EditorInspectorControlID] {
        registrations.keys.sorted { $0.rawValue < $1.rawValue }
    }

    func view(for value: EditorInspectorFieldValue,
              context: EditorInspectorFieldControlContext) -> AnyView? {
        guard let controlID = value.controlID, let binding = value.erasedBinding,
              let registration = registrations[controlID] else { return nil }
        return registration.control(binding, context)
    }

    func metrics(for value: EditorInspectorFieldValue) -> EditorInspectorFieldMetrics? {
        guard let controlID = value.controlID else { return nil }
        return registrations[controlID]?.metrics
    }

    /// Registers a control for a typed binding. `fallback` restores the value's
    /// type when the control reads the erased binding.
    mutating func register<Value>(controlID: EditorInspectorControlID,
                                  fallback: Value,
                                  layout: PropertyGridRowLayout = .twoColumn,
                                  sizing: PropertyGridRowSizing = .fixed,
                                  height: ((Binding<Value>, Float) -> Float?)? = nil,
                                  control: @escaping (Binding<Value>, EditorInspectorFieldControlContext) -> AnyView) throws {
        guard registrations[controlID] == nil else {
            throw EditorInspectorFieldControlError.duplicateControl(controlID)
        }
        registrations[controlID] = Registration(
            control: { erased, context in control(erased.typed(fallback: fallback), context) },
            metrics: EditorInspectorFieldMetrics(
                layout: layout, sizing: sizing,
                height: { erased, defaultHeight in
                    height?(erased.typed(fallback: fallback), defaultHeight)
                }))
    }

    /// Remove an existing control explicitly before replacing it.
    @discardableResult
    mutating func remove(controlID: EditorInspectorControlID) -> Bool {
        registrations.removeValue(forKey: controlID) != nil
    }
}

extension Binding<Any> {
    /// Reverses `erased()`. `fallback` only applies if a control was registered for
    /// the wrong type, which registration cannot express for built-ins.
    func typed<Typed>(fallback: Typed) -> Binding<Typed> {
        Binding<Typed>(
            get: { (wrappedValue as? Typed) ?? fallback },
            set: { wrappedValue = $0 })
    }
}
