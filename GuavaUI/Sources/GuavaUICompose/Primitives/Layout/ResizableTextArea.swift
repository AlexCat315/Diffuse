internal import GuavaUIRuntime

/// Multiline input with a draggable lower edge and internal text scrolling.
public struct ResizableTextArea: View {
    let text: Binding<TextBuffer>
    let placeholder: String
    let limits: EditorHeightLimits
    let resizeLabel: String
    let disabled: Bool
    let onSubmit: (() -> Void)?
    let onFocus: (() -> Void)?
    let onBlur: (() -> Void)?
    let codeEditing: TextFieldCodeEditing
    @State private var height: Float

    public init(_ placeholder: String = "", text: Binding<TextBuffer>, minHeight: Float = 96,
                maxHeight: Float = 360, disabled: Bool = false,
                resizeLabel: String = "Editor height",
                codeEditing: TextFieldCodeEditing = TextFieldCodeEditing(),
                onSubmit: (() -> Void)? = nil, onFocus: (() -> Void)? = nil, onBlur: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self.text = text
        limits = EditorHeightLimits(minimum: max(32, minHeight), maximum: maxHeight)
        self.resizeLabel = resizeLabel
        self.disabled = disabled
        self.codeEditing = codeEditing
        self.onSubmit = onSubmit
        self.onFocus = onFocus
        self.onBlur = onBlur
        _height = State(wrappedValue: limits.minimum)
    }
    public var body: some View {
        SurfaceReader { surface in
            let extent = surface.minimumControlExtent
            let viewportLimits = EditorHeightLimits(minimum: max(extent, limits.minimum), maximum: limits.maximum)
            let viewport = Binding(get: { viewportLimits.clamp(height) }, set: { height = viewportLimits.clamp($0) })
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                TextField(placeholder, text: text) { input in
                    input.layout.axis = .vertical
                    input.layout.maxVisibleLines = 128
                    input.codeEditing = codeEditing
                    input.behavior.disabled = disabled
                    input.events.onSubmit = onSubmit
                    input.events.onFocus = onFocus
                    input.events.onBlur = onBlur
                }
                    .frame(height: viewport.wrappedValue)
                    .flex(0, shrink: 0)
                EditorHeightHandle(value: viewport, limits: viewportLimits, label: resizeLabel,
                                   isEnabled: !disabled, extent: extent).debugName("editor-height-handle")
            }
        }
    }
}
