import CoveUICompose
import EngineKernel
import CoveUIRuntime
import RenderBackend

/// Displays a renderer-produced framebuffer inside CoveUI layout and forwards
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

package struct ViewportHost<Overlay: View>: _PrimitiveView {
    package let surface: ViewportSurfaceState
    package let automaticallyFocus: Bool
    package let contentAspectRatio: Float?
    package let onFocusChanged: ((Bool) -> Void)?
    package let onInputEvent: ((InputEvent) -> Void)?
    package let onDrawableSizeChange: ((RenderDrawableSize) -> Void)?
    package let onScreenFrameChange: ((ViewportScreenFrame) -> Void)?
    package let onDrawOverlay: ((DrawList, ViewportScreenFrame) -> Void)?
    package let overlay: Overlay

    package init(surface: ViewportSurfaceState,
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

    package func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = true
        node.automaticallyFocusOnPointerDown = false
        node.clipsToBounds = true
        return node
    }

    package func _updateNode(_ node: Node) {
        let snap = self
        if let cached = node.attachments["__viewport_image"] as? ImageCache,
           cached.output !== surface.image || !surface.isValid {
            node.attachments["__viewport_image"] = nil
        }
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
                if !event.input.isContinuation, let x = event.mouseX, let y = event.mouseY,
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

            guard snap.surface.isValid, let output = snap.surface.image else {
                return
            }

            let rect = UIRect(x: screenFrame.x, y: screenFrame.y,
                              width: screenFrame.width, height: screenFrame.height)
            let cache: ImageCache
            if let existing = node.attachments["__viewport_image"] as? ImageCache,
               existing.output === output {
                cache = existing
            } else {
                guard let image = try? TextureImage(texture: output.resource, mipmaps: output.mipmaps) else { return }
                cache = ImageCache(output: output, image: image)
                node.attachments["__viewport_image"] = cache
            }
            let selected = cache.image.resolution(for: SIMD2(rect.width, rect.height) * max(1, list.pixelScale),
                source: SIMD2(Float(snap.surface.region.size.width), Float(snap.surface.region.size.height)))
            list.retainResource(selected)
            // The engine renders into the top-left sub-region of a grow-only
            // allocated texture; crop to the used extent.
            let extent = snap.surface.region.uvMax
            let uvMax = (x: extent.x, y: extent.y)
            if selected === cache.image {
                list.addClampedImageQuad(rect: rect, textureID: selected.textureID,
                    texelSize: (1 / Float(snap.surface.region.capacity.width), 1 / Float(snap.surface.region.capacity.height)), uvMax: uvMax)
            } else {
                list.addImageQuad(rect: rect, textureID: selected.textureID)
            }

            snap.onDrawOverlay?(list, screenFrame)
        }
    }

    private struct ImageCache {
        let output: ViewportImage
        let image: TextureImage
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

    package func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        layout.flexGrow = 1
        return layout
    }

    package var _children: [any View] {
        [overlay]
    }
}

package enum ViewportPresentationGeometry {
    package static func fit(_ frame: ViewportScreenFrame, aspectRatio: Float?) -> ViewportScreenFrame {
        guard let aspectRatio, aspectRatio.isFinite, aspectRatio > 0,
              frame.width > 0, frame.height > 0 else { return frame }
        let width = min(frame.width, frame.height * aspectRatio)
        let height = width / aspectRatio
        return ViewportScreenFrame(x: frame.x + (frame.width - width) / 2,
                                   y: frame.y + (frame.height - height) / 2,
                                   width: width, height: height)
    }
}

package extension ViewportHost where Overlay == EmptyView {
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
