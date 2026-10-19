internal import GuavaUIRuntime

/// Vertical resize surface for multiline/code inputs. Drag the bottom grip;
/// content owns its text scrolling and the parent owns its surrounding layout.
public struct ResizableEditor<Content: View>: View {
    private let limits: EditorHeightLimits
    private let content: Content
    private let resizeLabel: String
    private let isResizable: Bool
    @State private var height: Float
    public init(initialHeight: Float = 160, minHeight: Float = 96, maxHeight: Float = 520,
                resizeLabel: String = "Editor height", isResizable: Bool = true,
                @ViewBuilder content: () -> Content) {
        limits = EditorHeightLimits(minimum: max(32, minHeight), maximum: maxHeight)
        _height = State(wrappedValue: limits.clamp(initialHeight))
        self.resizeLabel = resizeLabel; self.isResizable = isResizable
        self.content = content()
    }
    public var body: some View {
        SurfaceReader { surface in
            let extent = surface.minimumControlExtent
            let viewportLimits = EditorHeightLimits(minimum: max(extent, limits.minimum - extent),
                                                   maximum: limits.maximum - extent)
            let viewport = Binding(get: { viewportLimits.clamp(height - extent) },
                                   set: { height = viewportLimits.clamp($0) + extent })
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                content.flex(1, shrink: 1).frame(minHeight: 0)
                EditorHeightHandle(value: viewport, limits: viewportLimits, label: resizeLabel,
                                   isEnabled: isResizable, extent: extent)
                    .debugName("editor-height-handle")
            }.frame(height: viewport.wrappedValue + extent, minWidth: 0)
        }
    }
}
