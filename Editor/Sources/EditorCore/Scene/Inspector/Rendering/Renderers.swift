import SceneRuntime

public enum EditorInspectorRendererRegistrationError: Error, Equatable {
    case emptyComponentTypeID
    case duplicateRenderer(String)
}

/// Editor-session UI factories, keyed by the component registry's stable type ID.
/// Configure and invoke these on the adapter's UI thread. Factories receive the
/// adapter at render time so built-ins do not retain an owning scene adapter.
public struct EditorInspectorRendererRegistry {
    public typealias Renderer = (EditorSceneAdapter, EntityID) -> EditorInspectorSection?

    private var registrations: [String: EditorInspectorRendererRegistration] = [:]

    public init() {}

    public var componentTypeIDs: [String] { registrations.keys.sorted() }

    public subscript(componentTypeID: String) -> Renderer? { registrations[componentTypeID]?.render }

    public func registration(forComponentTypeID componentTypeID: String) -> EditorInspectorRendererRegistration? {
        registrations[componentTypeID]
    }

    /// Layout the property grid uses for this component's section. Generated
    /// forms, scene settings and unregistered components keep `.standard`.
    public func layout(forComponentTypeID componentTypeID: String) -> EditorInspectorSectionLayout {
        registrations[componentTypeID]?.layout ?? .standard
    }

    /// Applies the registered presentation pass, if the component declared one.
    /// Sections other components own are returned unchanged.
    public func presentedSection(_ section: EditorInspectorSection) -> EditorInspectorSection {
        guard let componentTypeID = section.componentTypeID,
              let presentation = registrations[componentTypeID]?.presentation else { return section }
        return presentation(section)
    }

    /// Remove an existing renderer explicitly before replacing it. Returning nil
    /// from a renderer delegates to the schema's generated field form.
    public mutating func register(_ registration: EditorInspectorRendererRegistration) throws {
        let componentTypeID = registration.componentTypeID
        guard !componentTypeID.isEmpty else {
            throw EditorInspectorRendererRegistrationError.emptyComponentTypeID
        }
        guard registrations[componentTypeID] == nil else {
            throw EditorInspectorRendererRegistrationError.duplicateRenderer(componentTypeID)
        }
        registrations[componentTypeID] = registration
    }

    public mutating func register(componentTypeID: String,
                                  layout: EditorInspectorSectionLayout = .standard,
                                  presentation: EditorInspectorRendererRegistration.Presentation? = nil,
                                  render: @escaping Renderer) throws {
        try register(EditorInspectorRendererRegistration(
            componentTypeID: componentTypeID, layout: layout, presentation: presentation, render: render))
    }

    @discardableResult
    public mutating func remove(componentTypeID: String) -> Renderer? {
        registrations.removeValue(forKey: componentTypeID)?.render
    }
}
