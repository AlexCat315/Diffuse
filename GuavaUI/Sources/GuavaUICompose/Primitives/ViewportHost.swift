import EngineKernel
import GuavaUIRuntime
import RenderBackend

/// Displays a renderer-produced framebuffer inside GuavaUI layout and forwards
/// viewport-local input to the owner.
public struct ViewportHost<Overlay: View>: _PrimitiveView {
    public let surface: ViewportSurfaceState
    public let onInputEvent: ((InputEvent) -> Void)?
    public let onDrawableSizeChange: ((RenderDrawableSize) -> Void)?
    public let overlay: Overlay

    public init(surface: ViewportSurfaceState,
                onInputEvent: ((InputEvent) -> Void)? = nil,
                onDrawableSizeChange: ((RenderDrawableSize) -> Void)? = nil,
                @ViewBuilder overlay: () -> Overlay) {
        self.surface = surface
        self.onInputEvent = onInputEvent
        self.onDrawableSizeChange = onDrawableSizeChange
        self.overlay = overlay()
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        node.clipsToBounds = true
        return node
    }

    public func _updateNode(_ node: Node) {
        let snap = self
        node.backgroundColor = node.theme.colors.surfaceSunken

        if let registry = InteractionRegistryHolder.current {
            registry.setPointer(node) { event, phase, _ in
                if phase == .down {
                    FocusChainHolder.current?.focus(node)
                    snap.onInputEvent?(.mouseButtonDown(event))
                } else {
                    snap.onInputEvent?(.mouseButtonUp(event))
                }
                return .handled
            }
            registry.setMotion(node) { event, _ in
                snap.onInputEvent?(.mouseMotion(event))
                return .handled
            }
            registry.setWheel(node) { event, _ in
                snap.onInputEvent?(.mouseWheel(event))
                return .handled
            }
            registry.setKey(node) { event, _ in
                snap.onInputEvent?(.keyDown(event))
                return .handled
            }
            registry.setText(node) { text, _ in
                snap.onInputEvent?(.textInput(text))
                return .handled
            }
            registry.setEditing(node) { event, _ in
                snap.onInputEvent?(.textEditing(event))
                return .handled
            }
        }

        node.draw = { list, origin in
            let width = UInt32(max(Int(node.frame.width.rounded()), 1))
            let height = UInt32(max(Int(node.frame.height.rounded()), 1))
            let drawableSize = RenderDrawableSize(width: width, height: height)
            let key = "__viewport_host_drawable_size"
            let previous = node.attachments[key] as? RenderDrawableSize
            if previous != drawableSize {
                node.attachments[key] = drawableSize
                snap.onDrawableSizeChange?(drawableSize)
            }

            guard let bridge = ViewportTextureBridgeHolder.current,
                  let textureID = bridge.textureID(surfaceID: snap.surface.surfaceID,
                                                  width: snap.surface.width,
                                                  height: snap.surface.height)
            else {
                return
            }

            let frame = node.frame
            let rect = UIRect(x: Float(origin.x),
                              y: Float(origin.y),
                              width: Float(frame.width),
                              height: Float(frame.height))
            list.addImageQuad(rect: rect, textureID: textureID, tint: .white)
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.flexGrow = 1
        return layout
    }

    public var _children: [any View] {
        [overlay]
    }
}

public extension ViewportHost where Overlay == EmptyView {
    init(surface: ViewportSurfaceState,
         onInputEvent: ((InputEvent) -> Void)? = nil,
         onDrawableSizeChange: ((RenderDrawableSize) -> Void)? = nil) {
        self.init(surface: surface,
                  onInputEvent: onInputEvent,
                  onDrawableSizeChange: onDrawableSizeChange) {
            EmptyView()
        }
    }
}