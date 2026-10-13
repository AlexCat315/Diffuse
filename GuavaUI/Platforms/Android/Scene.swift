import Foundation
import GuavaUICompose
import GuavaUIRuntime

/// Compose, input and font ownership for a native Android surface host.
/// Application content supplies a View; the platform adapter supplies surface frames.
public final class AndroidContentSession {
    public enum Rendering { case layers, direct }

    let tree = NodeTree()
    private let context = PlatformInputContext()
    private let recomposer = Recomposer()
    private let environment = SceneEnvironment()
    private let animations = AnimatorScheduler()
    private let rendering: Rendering
    private let touch = TouchInput()
    private let layers = LayerAwareNodeRenderer()
    private let nodes = NodeRenderer()
    private lazy var graph = ViewGraph(tree: tree, recomposer: recomposer)
    private lazy var dispatcher = EventDispatcher(tree: tree, interactions: context.interactions,
                                                  capture: context.pointerCapture, focusChain: context.focusChain)
    private var needsUpdate = true
    private let drawList = DrawList()
    public private(set) var logicalSize = SIMD2<Float>.zero
    public private(set) var scale: Float

    public init<Root: View>(scale: Float, rendering: Rendering = .layers, @ViewBuilder content: () -> Root) {
        self.scale = scale.isFinite ? min(4, max(1, scale)) : 1
        self.rendering = rendering
        environment.configure(scale: self.scale)
        withCurrent { graph.install(root: content()) }
    }

    public var needsFrame: Bool {
        needsUpdate || recomposer.hasPending || tree.hasRenderUpdates || animations.hasActiveAnimations || environment.hasWork
    }
    public var fontAtlas: FontAtlas { environment.text!.atlas }
    public var focusedID: String? {
        context.focusChain.focused.map { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String ?? "field.\($0.id)" }
    }
    public var preedit: String { context.focusChain.focused?.attachments["preedit"] as? String ?? "" }
    public var editorSnapshot: TextInputClient.Snapshot? { withCurrent { textClient?.snapshot() } }
    private var textClient: TextInputClient? { context.focusChain.focused?.attachments[TextInputAttachmentKey.client] as? TextInputClient }

    private func withCurrent<R>(_ body: () throws -> R) rethrows -> R {
        try AnimatorScheduler.$current.withValue(animations) {
            try environment.withCurrent(scale: scale) { try context.withCurrent(body) }
        }
    }

    @discardableResult
    public func prepare(pixels: SIMD2<Int>, scale: Float, deltaTime: Double) -> DrawList {
        self.scale = scale.isFinite ? min(4, max(1, scale)) : 1
        logicalSize = SIMD2(Float(pixels.x), Float(pixels.y)) / self.scale
        withCurrent {
            environment.drain()
            animations.tick(deltaTime: deltaTime)
            recomposer.commitAll()
            graph.computeLayoutIfNeeded(width: logicalSize.x, height: logicalSize.y)
            drawList.reset(); drawList.pixelScale = self.scale
            if rendering == .direct { if let root = tree.root { nodes.render(root: root, into: drawList) } }
            else { layers.render(tree: graph.renderTree, into: drawList) }
        }
        let drawing = DrawList()
        drawing.load(vertices: drawList.vertices, indices: drawList.indices, batches: drawList.batches, resources: drawList.resources)
        drawing.pixelScale = drawList.pixelScale
        drawing.setViewportBounds(drawList.viewportBounds)
        return drawing
    }

    public func didPresent() { needsUpdate = false; tree.flush() }
    public func invalidate() { needsUpdate = true }
    public func suspend() {
        withCurrent { context.pointerCapture.release(); context.focusChain.focus(nil) }
    }

    public func pointer(kind: Int32, x: Float, y: Float) {
        guard x.isFinite, y.isFinite else { return }
        let point = SIMD2(x, y) / scale
        withCurrent {
            if kind == 4 {
                context.pointerCapture.release()
                let event = MouseButtonEvent(button: .right, x: point.x, y: point.y, clicks: 1)
                dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
            } else if kind == 5 {
                dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: point.x, y: point.y, deltaX: 0, deltaY: 0)))
            } else { touch.route(kind: kind, point: point, tree: tree, context: context, dispatcher: dispatcher) }
        }
        needsUpdate = true
    }

    public func text(_ string: String, composing: Bool) {
        guard string.utf8.count <= 32768 else { return }
        _ = withCurrent {
            if composing { dispatcher.dispatch(.textEditing(TextEditingEvent(text: string, start: 0, length: Int32(string.utf16.count)))) }
            else { dispatcher.dispatch(.textInput(string)) }
        }
        needsUpdate = true
    }

    public func key(_ scancode: UInt32, modifiers: KeyModifiers = []) {
        withCurrent {
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)))
            dispatcher.dispatch(.keyUp(KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)))
        }
        needsUpdate = true
    }

    public func edit(kind: Int32, start: Int, end: Int) {
        withCurrent {
            if kind == 2 || kind == 3 {
                (context.focusChain.focused?.attachments[TextInputAttachmentKey.editActions] as? TextEditActions)?.perform(kind == 2 ? .undo : .redo)
            } else if let textClient {
                if kind == 0 { textClient.select(start, end) }
                else { textClient.deleteSurrounding(start, end) }
            } else if kind == 1 { for _ in 0..<min(32768, max(0, start)) { key(42) } }
        }
        needsUpdate = true
    }

    public func scroll(x: Float, y: Float, deltaX: Float, deltaY: Float) {
        guard x.isFinite, y.isFinite, deltaX.isFinite, deltaY.isFinite else { return }
        _ = withCurrent {
            dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: deltaX, y: deltaY, mouseX: x / scale, mouseY: y / scale,
                input: ScrollInput(unit: .lines, device: .wheel))))
        }
        needsUpdate = true
    }
}
