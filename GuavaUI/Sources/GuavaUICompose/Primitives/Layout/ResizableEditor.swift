import Foundation
import GuavaUIRuntime

/// Vertical resize surface for multiline/code inputs. Drag the bottom grip;
/// content owns its text scrolling and the parent owns its surrounding layout.
public struct ResizableEditor<Content: View>: View {
    private let minimum: Float; private let maximum: Float; private let content: Content
    @State private var height: Float
    public init(initialHeight: Float = 160, minHeight: Float = 96, maxHeight: Float = 520,
                @ViewBuilder content: () -> Content) {
        minimum = max(32, minHeight); maximum = max(minimum, maxHeight)
        _height = State(wrappedValue: max(minimum, min(maximum, initialHeight)))
        self.content = content()
    }
    public var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            content.flex(1, shrink: 1).frame(minHeight: 0)
            _EditorResizeGrip(height: $height, minimum: minimum, maximum: maximum)
        }.frame(height: height, minWidth: 0)
    }
}

private struct _EditorResizeGrip: _PrimitiveView {
    let height: Binding<Float>; let minimum: Float; let maximum: Float
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = true; node.cursor = .resizeVertical
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.height = 8; return layout }
    func _updateNode(_ node: Node) {
        InteractionRegistryHolder.current?.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            if phase == .down {
                node.attachments["resize-start"] = (event.y, height.wrappedValue)
                PointerCaptureHolder.current?.acquire(node)
            } else {
                node.attachments.removeValue(forKey: "resize-start")
                PointerCaptureHolder.current?.release()
            }
            return .handled
        }
        InteractionRegistryHolder.current?.setMotion(node) { event, _ in
            guard let (startY, startHeight) = node.attachments["resize-start"] as? (Float, Float),
                  PointerCaptureHolder.current?.target === node else { return .ignored }
            height.wrappedValue = max(minimum, min(maximum, startHeight + event.y - startY))
            return .handled
        }
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            list.addRoundedRect(UIRect(x: Float(origin.x) + max(0, Float(node.frame.width) / 2 - 12),
                                      y: Float(origin.y) + 3, width: 24, height: 2),
                                radius: 1, color: node.theme.colors.onSurfaceMuted.multipliedAlpha(0.5))
        }
    }
    var _children: [any View] { [] }
}
