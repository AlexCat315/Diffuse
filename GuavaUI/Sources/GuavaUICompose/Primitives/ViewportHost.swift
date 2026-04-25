import EngineKernel
import GuavaUIRuntime
import RenderBackend

/// Displays a renderer-produced framebuffer inside GuavaUI layout and forwards
/// viewport-local input to the owner.
/// Screen-space rect of the viewport surface, in window/event coordinates.
public struct ViewportScreenFrame: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(x px: Float, y py: Float) -> Bool {
        px >= x && py >= y && px < x + width && py < y + height
    }
}

public struct ViewportHost<Overlay: View>: _PrimitiveView {
    public let surface: ViewportSurfaceState
    public let onInputEvent: ((InputEvent) -> Void)?
    public let onDrawableSizeChange: ((RenderDrawableSize) -> Void)?
    public let onScreenFrameChange: ((ViewportScreenFrame) -> Void)?
    public let onDrawOverlay: ((DrawList, ViewportScreenFrame) -> Void)?
    public let overlay: Overlay

    public init(surface: ViewportSurfaceState,
                onInputEvent: ((InputEvent) -> Void)? = nil,
                onDrawableSizeChange: ((RenderDrawableSize) -> Void)? = nil,
                onScreenFrameChange: ((ViewportScreenFrame) -> Void)? = nil,
                onDrawOverlay: ((DrawList, ViewportScreenFrame) -> Void)? = nil,
                @ViewBuilder overlay: () -> Overlay) {
        self.surface = surface
        self.onInputEvent = onInputEvent
        self.onDrawableSizeChange = onDrawableSizeChange
        self.onScreenFrameChange = onScreenFrameChange
        self.onDrawOverlay = onDrawOverlay
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
        node.animatableSet(\.backgroundColor, to: snap.surface.isValid
            ? node.theme.colors.surfaceSunken
            : node.theme.colors.surfaceVariant)

        if let registry = InteractionRegistryHolder.current {
            registry.setPointer(node, route: .viewport) { event, phase, _ in
                if phase == .down {
                    FocusChainHolder.current?.focus(node)
                    snap.onInputEvent?(.mouseButtonDown(event))
                } else {
                    snap.onInputEvent?(.mouseButtonUp(event))
                }
                return .handled
            }
            registry.setMotion(node, route: .viewport) { event, _ in
                snap.onInputEvent?(.mouseMotion(event))
                return .handled
            }
            registry.setWheel(node, route: .viewport) { event, _ in
                snap.onInputEvent?(.mouseWheel(event))
                return .handled
            }
            registry.setKey(node, route: .viewport) { event, _ in
                snap.onInputEvent?(.keyDown(event))
                return .handled
            }
            registry.setKeyUp(node, route: .viewport) { event, _ in
                snap.onInputEvent?(.keyUp(event))
                return .handled
            }
            registry.setText(node, route: .viewport) { text, _ in
                snap.onInputEvent?(.textInput(text))
                return .handled
            }
            registry.setEditing(node, route: .viewport) { event, _ in
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

            let frame = node.frame
            let screenFrame = ViewportScreenFrame(x: Float(origin.x),
                                                  y: Float(origin.y),
                                                  width: Float(frame.width),
                                                  height: Float(frame.height))
            let frameKey = "__viewport_host_screen_frame"
            let previousFrame = node.attachments[frameKey] as? ViewportScreenFrame
            if previousFrame != screenFrame {
                node.attachments[frameKey] = screenFrame
                snap.onScreenFrameChange?(screenFrame)
            }

            guard let bridge = ViewportTextureBridgeHolder.current,
                  let textureID = bridge.textureID(surfaceID: snap.surface.surfaceID,
                                                  handle: snap.surface.handle,
                                                  width: snap.surface.width,
                                                  height: snap.surface.height)
            else {
                return
            }

            let rect = UIRect(x: Float(origin.x),
                              y: Float(origin.y),
                              width: Float(frame.width),
                              height: Float(frame.height))
            list.addImageQuad(rect: rect, textureID: textureID, tint: .white)

            snap.onDrawOverlay?(list, screenFrame)
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
         onDrawableSizeChange: ((RenderDrawableSize) -> Void)? = nil,
         onScreenFrameChange: ((ViewportScreenFrame) -> Void)? = nil,
         onDrawOverlay: ((DrawList, ViewportScreenFrame) -> Void)? = nil) {
        self.init(surface: surface,
                  onInputEvent: onInputEvent,
                  onDrawableSizeChange: onDrawableSizeChange,
                  onScreenFrameChange: onScreenFrameChange,
                  onDrawOverlay: onDrawOverlay) {
            EmptyView()
        }
    }
}
