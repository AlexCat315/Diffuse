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
    public let automaticallyFocus: Bool
    public let contentAspectRatio: Float?
    public let onFocusChanged: ((Bool) -> Void)?
    public let onInputEvent: ((InputEvent) -> Void)?
    public let onDrawableSizeChange: ((RenderDrawableSize) -> Void)?
    public let onScreenFrameChange: ((ViewportScreenFrame) -> Void)?
    public let onDrawOverlay: ((DrawList, ViewportScreenFrame) -> Void)?
    public let overlay: Overlay

    public init(surface: ViewportSurfaceState,
                automaticallyFocus: Bool = false,
                contentAspectRatio: Float? = nil,
                onFocusChanged: ((Bool) -> Void)? = nil,
                onInputEvent: ((InputEvent) -> Void)? = nil,
                onDrawableSizeChange: ((RenderDrawableSize) -> Void)? = nil,
                onScreenFrameChange: ((ViewportScreenFrame) -> Void)? = nil,
                onDrawOverlay: ((DrawList, ViewportScreenFrame) -> Void)? = nil,
                @ViewBuilder overlay: () -> Overlay) {
        self.surface = surface
        self.automaticallyFocus = automaticallyFocus
        self.contentAspectRatio = contentAspectRatio
        self.onFocusChanged = onFocusChanged
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
        node.automaticallyFocusOnPointerDown = false
        node.clipsToBounds = true
        return node
    }

    public func _updateNode(_ node: Node) {
        let snap = self
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { (focused: Bool) -> Void in
            snap.onFocusChanged?(focused)
        }
        // A standalone game owns the initial keyboard target. Embedded editor
        // viewports retain click-to-focus and never take another control's focus.
        if snap.automaticallyFocus, node.attachments["__viewport_initial_focus"] == nil,
           let focus = FocusChainHolder.current, focus.focused == nil {
            focus.focus(node, visible: false)
            if focus.focused === node { node.attachments["__viewport_initial_focus"] = true }
        }
        node.animatableSet(\.backgroundColor, to: snap.surface.isValid
            ? node.theme.colors.surfaceSunken
            : node.theme.colors.surfaceVariant)

        if let registry = InteractionRegistryHolder.current {
            registry.setPointer(node, route: .viewport) { event, pointerPhase, eventPhase in
                guard eventPhase == .target else { return .ignored }
                if pointerPhase == .down {
                    guard snap.imageFrame(in: node).contains(x: event.x, y: event.y) else {
                        if FocusChainHolder.current?.focused === node { FocusChainHolder.current?.clear() }
                        return .ignored
                    }
                    FocusChainHolder.current?.focus(node)
                    PointerCaptureHolder.current?.acquire(node)
                    snap.onInputEvent?(.mouseButtonDown(event))
                } else {
                    guard PointerCaptureHolder.current?.target === node
                        || snap.imageFrame(in: node).contains(x: event.x, y: event.y) else { return .ignored }
                    snap.onInputEvent?(.mouseButtonUp(event))
                    if PointerCaptureHolder.current?.target === node {
                        PointerCaptureHolder.current?.release()
                    }
                }
                return .handled
            }
            registry.setMotion(node, route: .viewport) { event, phase in
                guard phase == .target else { return .ignored }
                guard PointerCaptureHolder.current?.target === node
                    || snap.imageFrame(in: node).contains(x: event.x, y: event.y) else { return .ignored }
                snap.onInputEvent?(.mouseMotion(event))
                return .handled
            }
            registry.setWheel(node, route: .viewport) { event, phase in
                guard phase == .target else { return .ignored }
                if let x = event.mouseX, let y = event.mouseY,
                   !snap.imageFrame(in: node).contains(x: x, y: y) { return .ignored }
                snap.onInputEvent?(.mouseWheel(event))
                return .handled
            }
            registry.setKey(node, route: .viewport) { event, _ in
                snap.onInputEvent?(.keyDown(event))
                return Self.consumesKey(event) ? .handled : .ignored
            }
            registry.setKeyUp(node, route: .viewport) { event, _ in
                snap.onInputEvent?(.keyUp(event))
                return Self.consumesKey(event) ? .handled : .ignored
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

        node.updateDraw(identity: DrawIdentity(surface: snap.surface, aspectRatio: snap.contentAspectRatio)) { list, origin in
            // Report the drawable in physical pixels: the layout frame is in
            // logical points, so honor the window's content scale or the
            // scene renders at 1/scale² resolution and gets upscaled blurry.
            let scale = CGFloat(max(1, ContentScaleHolder.current))
            let screenFrame = ViewportPresentationGeometry.fit(
                ViewportScreenFrame(x: Float(origin.x), y: Float(origin.y),
                    width: Float(node.frame.width), height: Float(node.frame.height)),
                aspectRatio: snap.contentAspectRatio)
            let width = UInt32(max(Int((CGFloat(screenFrame.width) * scale).rounded()), 1))
            let height = UInt32(max(Int((CGFloat(screenFrame.height) * scale).rounded()), 1))
            let drawableSize = RenderDrawableSize(width: width, height: height)
            let key = "__viewport_host_drawable_size"
            let previous = node.attachments[key] as? RenderDrawableSize
            if previous != drawableSize {
                node.attachments[key] = drawableSize
                snap.onDrawableSizeChange?(drawableSize)
            }

            let frameKey = "__viewport_host_screen_frame"
            let previousFrame = node.attachments[frameKey] as? ViewportScreenFrame
            if previousFrame != screenFrame {
                node.attachments[frameKey] = screenFrame
                snap.onScreenFrameChange?(screenFrame)
            }

            guard let bridge = ViewportTextureBridgeHolder.current,
                  let textureID = bridge.textureID(surfaceID: snap.surface.surfaceID,
                                                  handle: snap.surface.handle,
                                                  width: snap.surface.textureWidth,
                                                  height: snap.surface.textureHeight)
            else {
                return
            }

            let rect = UIRect(x: screenFrame.x, y: screenFrame.y,
                              width: screenFrame.width, height: screenFrame.height)
            // The engine renders into the top-left sub-region of a grow-only
            // allocated texture; crop to the used extent.
            let uvMax: (x: Float, y: Float) = (
                snap.surface.textureWidth > 0
                    ? Float(snap.surface.width) / Float(snap.surface.textureWidth) : 1,
                snap.surface.textureHeight > 0
                    ? Float(snap.surface.height) / Float(snap.surface.textureHeight) : 1
            )
            list.addImageQuad(rect: rect, textureID: textureID, tint: .white, uvMax: uvMax)

            snap.onDrawOverlay?(list, screenFrame)
        }
    }

    private struct DrawIdentity: Equatable {
        let surface: ViewportSurfaceState
        let aspectRatio: Float?
    }

    private func imageFrame(in node: Node) -> ViewportScreenFrame {
        let bounds = node.absoluteFrame
        return ViewportPresentationGeometry.fit(
            ViewportScreenFrame(x: Float(bounds.minX), y: Float(bounds.minY),
                                width: Float(bounds.width), height: Float(bounds.height)),
            aspectRatio: contentAspectRatio)
    }

    /// The viewport owns raw keys (camera, game input) while focused, but
    /// Cmd/Ctrl chords stay with app-level shortcuts. Events are forwarded to
    /// `onInputEvent` either way so pressed-key bookkeeping stays complete.
    private static func consumesKey(_ event: KeyEvent) -> Bool {
        !event.modifiers.hasGui && !event.modifiers.hasCtrl
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

public enum ViewportPresentationGeometry {
    public static func fit(_ frame: ViewportScreenFrame, aspectRatio: Float?) -> ViewportScreenFrame {
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0,
              frame.width > 0, frame.height > 0 else { return frame }
        let width = min(frame.width, frame.height * aspectRatio)
        let height = width / aspectRatio
        return ViewportScreenFrame(x: frame.x + (frame.width - width) / 2,
                                   y: frame.y + (frame.height - height) / 2,
                                   width: width, height: height)
    }
}

public extension ViewportHost where Overlay == EmptyView {
    init(surface: ViewportSurfaceState,
         automaticallyFocus: Bool = false,
         onInputEvent: ((InputEvent) -> Void)? = nil,
         onDrawableSizeChange: ((RenderDrawableSize) -> Void)? = nil,
         onScreenFrameChange: ((ViewportScreenFrame) -> Void)? = nil,
         onDrawOverlay: ((DrawList, ViewportScreenFrame) -> Void)? = nil) {
        self.init(surface: surface,
                  automaticallyFocus: automaticallyFocus,
                  onInputEvent: onInputEvent,
                  onDrawableSizeChange: onDrawableSizeChange,
                  onScreenFrameChange: onScreenFrameChange,
                  onDrawOverlay: onDrawOverlay) {
            EmptyView()
        }
    }
}
