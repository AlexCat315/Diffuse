#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import GuavaUIRuntime

/// Multiline input with a draggable lower edge and internal text scrolling.
public struct ResizableTextArea: View {
    let text: Binding<String>
    let placeholder: String
    let minHeight: Float
    let maxHeight: Float
    let disabled: Bool
    let onSubmit: (() -> Void)?
    let onFocus: (() -> Void)?
    let onBlur: (() -> Void)?
    @State private var height: Float

    public init(_ placeholder: String = "", text: Binding<String>, minHeight: Float = 96,
                maxHeight: Float = 360, disabled: Bool = false,
                onSubmit: (() -> Void)? = nil, onFocus: (() -> Void)? = nil, onBlur: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self.text = text
        self.minHeight = max(32, minHeight)
        self.maxHeight = max(self.minHeight, maxHeight)
        self.disabled = disabled
        self.onSubmit = onSubmit
        self.onFocus = onFocus
        self.onBlur = onBlur
        _height = State(wrappedValue: max(32, minHeight))
    }
    public var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            TextField(placeholder, text: text, axis: .vertical, maxVisibleLines: 128,
                      disabled: disabled, onSubmit: onSubmit, onFocus: onFocus, onBlur: onBlur)
                .font(.mono)
                .frame(height: height)
                .flex(0, shrink: 0)
            _TextAreaResizeHandle(height: height, isEnabled: !disabled, onResize: { next in
                let bounded = min(maxHeight, max(minHeight, next))
                if height != bounded { height = bounded }
            })
        }
    }
}

private struct _TextAreaResizeHandle: _PrimitiveView {
    let height: Float
    let isEnabled: Bool
    let onResize: (Float) -> Void
    func _makeNode() -> Node { Node() }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.height = 10
        layout.flexShrink = 0
        layout.alignItems = .center
        layout.justifyContent = .center
        return layout
    }
    func _updateNode(_ node: Node) {
        node.isHitTestable = isEnabled
        node.cursor = .resizeVertical
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setPointer(node) { event, phase, _ in
            guard isEnabled, event.button == .left else { return .ignored }
            if phase == .down {
                node.attachments["textarea.resizeStart"] = (event.y, height)
                PointerCaptureHolder.current?.acquire(node)
            } else {
                node.attachments.removeValue(forKey: "textarea.resizeStart")
                PointerCaptureHolder.current?.release()
            }
            return .handled
        }
        registry.setMotion(node) { event, _ in
            guard let (startY, startHeight) = node.attachments["textarea.resizeStart"] as? (Float, Float) else { return .ignored }
            onResize(startHeight + event.y - startY)
            return .handled
        }
    }
    var _children: [any View] {
        [Box { EmptyView() }.frame(width: 26, height: 2).background(.border).cornerRadius(1)]
    }
}
