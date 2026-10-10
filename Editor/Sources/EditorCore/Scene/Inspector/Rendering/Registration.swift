import SceneRuntime

/// One explicit component → UI entry: the section factory, the property-grid
/// layout its fields are shaped for, and an optional presentation pass applied
/// to the produced section.
///
/// Registrations are values, not a string-keyed dispatch table, so native modules
/// and, later, plugin hosts can build and register them from data.
public struct EditorInspectorRendererRegistration {
    public typealias Renderer = EditorInspectorRendererRegistry.Renderer
    public typealias Presentation = (EditorInspectorSection) -> EditorInspectorSection

    public var componentTypeID: String
    public var layout: EditorInspectorSectionLayout
    public var render: Renderer
    public var presentation: Presentation?

    public init(componentTypeID: String,
                layout: EditorInspectorSectionLayout = .standard,
                presentation: Presentation? = nil,
                render: @escaping Renderer) {
        self.componentTypeID = componentTypeID
        self.layout = layout
        self.render = render
        self.presentation = presentation
    }
}
