import Foundation
import GuavaUIComposeCore
import GuavaUISharedDemo
import GuavaUIText

/// Owns Compose, layout and input state independently of an Android surface.
final class DemoScene {
    struct Bounds: Codable {
        let x: Float
        let y: Float
        let width: Float
        let height: Float
        init(_ rect: CGRect) {
            x = Float(rect.minX); y = Float(rect.minY)
            width = Float(rect.width); height = Float(rect.height)
        }
    }
    struct Snapshot: Codable {
        let session: String
        let state: [String: String]
        let focused: String?
        let preedit: String
        let controls: [String: Bounds]
        let width: Float
        let height: Float
        let scale: Float
        let typography: DemoTypography.Statistics
        let vertices: Int
        let indices: Int
        let frames: Int
    }
    let counter = SharedCounterView()
    let tree = NodeTree()
    let context = PlatformInputContext()
    let recomposer = Recomposer()
    let typography: DemoTypography
    let list = DrawList()
    lazy var graph = ViewGraph(tree: tree, recomposer: recomposer)
    lazy var dispatcher = EventDispatcher(tree: tree, interactions: context.interactions,
                                         capture: context.pointerCapture, focusChain: context.focusChain)
    private(set) var size: SIMD2<Float> = .zero
    private(set) var scale: Float = 1
    private var frames = 0
    private var needsUpdate = true
    private let sessionID = UUID().uuidString

    init(checkpoint: String) throws {
        typography = try DemoTypography()
        if let data = checkpoint.data(using: .utf8), !checkpoint.isEmpty {
            let values = try JSONDecoder().decode([String: String].self, from: data)
            guard counter.restore(values) else { throw CocoaError(.coderReadCorrupt) }
        }
        context.withCurrent {
            graph.install(root: counter.compositionLocal(SharedDemoText.painter, { [weak self] text, list, origin in
                guard let self else { return }
                typography.paint(text, into: list, origin: origin, scale: scale)
            }))
        }
    }

    var needsFrame: Bool { needsUpdate || recomposer.hasPending || tree.hasRenderUpdates }
    var hasTextFocus: Bool { context.focusChain.focused?.attachments[LayoutDebugAttachmentKey.debugName] as? String == "counter.note" }

    func prepare(pixels: SIMD2<Int>, scale: Float) {
        self.scale = min(4, max(1, scale))
        size = SIMD2(Float(pixels.x), Float(pixels.y)) / self.scale
        context.withCurrent {
            recomposer.commitAll()
            graph.computeLayoutIfNeeded(width: size.x, height: size.y)
            list.reset()
            list.pixelScale = self.scale
            typography.beginFrame()
            if let root = tree.root { NodeRenderer().render(root: root, into: list) }
            if typography.fonts.atlas.isFull, let root = tree.root {
                typography.fonts.atlas.reset()
                list.reset(); list.pixelScale = self.scale
                typography.beginFrame()
                NodeRenderer().render(root: root, into: list)
            }
            typography.finishFrame()
        }
    }

    func didPresent() { frames += 1; needsUpdate = false; tree.flush() }

    func pointer(kind: Int32, x: Float, y: Float) {
        guard x.isFinite, y.isFinite else { return }
        let point = SIMD2(x, y) / scale
        context.withCurrent {
            let event = MouseButtonEvent(button: .left, x: point.x, y: point.y, clicks: 1)
            switch kind {
            case 0: dispatcher.dispatch(.mouseButtonDown(event))
            case 1: dispatcher.dispatch(.mouseButtonUp(event))
            case 2: dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: point.x, y: point.y, deltaX: 0, deltaY: 0)))
            case 3: context.pointerCapture.release()
            default: break
            }
        }
        needsUpdate = true
    }

    func text(_ string: String, composing: Bool) {
        guard string.utf8.count <= 32768 else { return }
        context.withCurrent {
            if composing { dispatcher.dispatch(.textEditing(TextEditingEvent(text: string, start: 0, length: Int32(string.utf16.count)))) }
            else { dispatcher.dispatch(.textInput(string)) }
        }
        needsUpdate = true
    }

    func key(_ scancode: UInt32) {
        context.withCurrent {
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: scancode, keycode: 0, modifiers: [], isRepeat: false)))
            dispatcher.dispatch(.keyUp(KeyEvent(scancode: scancode, keycode: 0, modifiers: [], isRepeat: false)))
        }
        needsUpdate = true
    }

    func snapshot() -> String {
        var controls: [String: Bounds] = [:]
        func visit(_ node: Node) {
            if let name = node.attachments[LayoutDebugAttachmentKey.debugName] as? String { controls[name] = Bounds(node.absoluteFrame) }
            for child in node.children { visit(child) }
        }
        if let root = tree.root { visit(root) }
        let focus = context.focusChain.focused
        let value = Snapshot(session: sessionID, state: counter.checkpoint,
            focused: focus?.attachments[LayoutDebugAttachmentKey.debugName] as? String,
            preedit: focus?.attachments["preedit"] as? String ?? "", controls: controls,
            width: size.x, height: size.y, scale: scale, typography: typography.statistics,
            vertices: list.vertices.count, indices: list.indices.count, frames: frames)
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
