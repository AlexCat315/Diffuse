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

    private var renderers: [String: Renderer] = [:]

    public init() {}

    public var componentTypeIDs: [String] { renderers.keys.sorted() }

    public subscript(componentTypeID: String) -> Renderer? { renderers[componentTypeID] }

    /// Remove an existing renderer explicitly before replacing it. Returning nil
    /// from a renderer delegates to the schema's generated field form.
    public mutating func register(componentTypeID: String, render: @escaping Renderer) throws {
        guard !componentTypeID.isEmpty else {
            throw EditorInspectorRendererRegistrationError.emptyComponentTypeID
        }
        guard renderers[componentTypeID] == nil else {
            throw EditorInspectorRendererRegistrationError.duplicateRenderer(componentTypeID)
        }
        renderers[componentTypeID] = render
    }

    @discardableResult
    public mutating func remove(componentTypeID: String) -> Renderer? {
        renderers.removeValue(forKey: componentTypeID)
    }
}
