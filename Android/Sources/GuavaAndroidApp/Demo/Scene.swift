import Foundation
import GuavaUIComposeCore
import GuavaUISharedDemo
import GuavaUIText
import GuavaUICompose
import GuavaUIGallery
import GuavaUIRuntime
import NativeRHI

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
        let mode: String
        let page: String?
        let game: GameSession.Snapshot?
        let editor: TextInputClient.Snapshot?
        let nodes: [SemanticNode]
    }
    let counter = SharedCounterView()
    let tree = NodeTree()
    let context = PlatformInputContext()
    let recomposer = Recomposer()
    let typography: DemoTypography
    let environment = SceneEnvironment()
    let animations = AnimatorScheduler()
    let launch: SceneLaunch
    let gallery: GalleryView
    let list = DrawList()
    lazy var graph = ViewGraph(tree: tree, recomposer: recomposer)
    lazy var dispatcher = EventDispatcher(tree: tree, interactions: context.interactions,
                                         capture: context.pointerCapture, focusChain: context.focusChain)
    private(set) var size: SIMD2<Float> = .zero
    private(set) var scale: Float = 1
    private var frames = 0
    private var needsUpdate = true
    private let sessionID = UUID().uuidString
    let game: GameSession?
    private let touch = TouchInput()

    init(checkpoint: String, launch: SceneLaunch, scale: Float, device: Device) throws {
        self.launch = launch
        game = try launch.mode == .game ? GameSession(device: device, project: launch.project ?? "GuavaProject") : nil
        gallery = GalleryView(initialPage: GalleryCatalog.page(named: launch.component) ?? .introduction)
        typography = try DemoTypography()
        self.scale = scale
        environment.configure(scale: scale)
        if let data = checkpoint.data(using: .utf8), !checkpoint.isEmpty {
            let values = try JSONDecoder().decode([String: String].self, from: data)
            if launch.mode == .counter {
                guard counter.restore(values) else { throw CocoaError(.coderReadCorrupt) }
            } else if let page = values["page"].flatMap(GalleryCatalog.page(named:)) { gallery.selectPage(page) }
        }
        withCurrent {
            if launch.mode == .gallery { graph.install(root: gallery) }
            else if launch.mode == .counter { graph.install(root: counter.compositionLocal(SharedDemoText.painter, { [weak self] text, list, origin in
                guard let self else { return }
                typography.paint(text, into: list, origin: origin, scale: scale)
            })) }
        }
    }

    func withCurrent<R>(_ body: () throws -> R) rethrows -> R {
        try AnimatorScheduler.$current.withValue(animations) {
            try environment.withCurrent(scale: scale) { try context.withCurrent(body) }
        }
    }

    var needsFrame: Bool { game != nil || needsUpdate || recomposer.hasPending || tree.hasRenderUpdates || animations.hasActiveAnimations || environment.hasWork }
    var textClient: TextInputClient? { context.focusChain.focused?.attachments[TextInputAttachmentKey.client] as? TextInputClient }
    var hasTextFocus: Bool { textClient != nil || context.focusChain.focused?.attachments[LayoutDebugAttachmentKey.debugName] as? String == "counter.note" }
    var editorSnapshot: TextInputClient.Snapshot? {
        if let textClient { return withCurrent { textClient.snapshot() } }
        guard hasTextFocus else { return nil }
        let value = counter.checkpoint["note", default: ""]
        let preedit = context.focusChain.focused?.attachments["preedit"] as? String ?? ""
        let caret = value.utf16.count + preedit.utf16.count
        return .init(text: value + preedit, selectionStart: caret, selectionEnd: caret,
                     compositionStart: preedit.isEmpty ? -1 : value.utf16.count, compositionEnd: preedit.isEmpty ? -1 : caret)
    }
    func edit(kind: Int32, start: Int, end: Int) {
        withCurrent {
            if kind == 2 || kind == 3 {
                (context.focusChain.focused?.attachments[TextInputAttachmentKey.editActions] as? TextEditActions)?.perform(kind == 2 ? .undo : .redo)
                return
            }
            if let textClient {
                if kind == 0 { textClient.select(start, end) }
                else { textClient.deleteSurrounding(start, end) }
            } else if kind == 1 { for _ in 0..<min(32768, max(0, start)) { key(42) } }
        }
        needsUpdate = true
    }

    func prepare(pixels: SIMD2<Int>, scale: Float, deltaTime: Double) {
        self.scale = min(4, max(1, scale))
        size = SIMD2(Float(pixels.x), Float(pixels.y)) / self.scale
        if let game {
            game.prepare(pixels: pixels, scale: self.scale, deltaTime: deltaTime)
            list.reset(); list.pixelScale = self.scale
            if game.surface.isValid {
                let uv = game.surface.region.uvMax
                list.addImageQuad(rect: UIRect(x: 0, y: 0, width: size.x, height: size.y), textureID: 2, uvMax: (uv.x, uv.y))
            }
            return
        }
        withCurrent {
            environment.drain()
            animations.tick(deltaTime: deltaTime)
            recomposer.commitAll()
            graph.computeLayoutIfNeeded(width: size.x, height: size.y)
            list.reset()
            list.pixelScale = self.scale
            typography.beginFrame()
            if let root = tree.root {
                if launch.mode == .gallery { LayerAwareNodeRenderer().render(tree: graph.renderTree, into: list) }
                else { NodeRenderer().render(root: root, into: list) }
            }
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
    func invalidate() { needsUpdate = true }
    func suspend() {
        withCurrent {
            context.pointerCapture.release()
            context.focusChain.focus(nil)
        }
        game?.releaseKeys()
    }

    func pointer(kind: Int32, x: Float, y: Float) {
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

    func text(_ string: String, composing: Bool) {
        guard string.utf8.count <= 32768 else { return }
        _ = withCurrent {
            if composing { dispatcher.dispatch(.textEditing(TextEditingEvent(text: string, start: 0, length: Int32(string.utf16.count)))) }
            else { dispatcher.dispatch(.textInput(string)) }
        }
        needsUpdate = true
    }

    func key(_ scancode: UInt32, modifiers: KeyModifiers = []) {
        if let game { game.key(scancode, down: true); game.key(scancode, down: false); return }
        withCurrent {
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)))
            dispatcher.dispatch(.keyUp(KeyEvent(scancode: scancode, keycode: 0, modifiers: modifiers, isRepeat: false)))
        }
        needsUpdate = true
    }

    func scroll(x: Float, y: Float, deltaX: Float, deltaY: Float) {
        guard x.isFinite, y.isFinite, deltaX.isFinite, deltaY.isFinite else { return }
        _ = withCurrent {
            dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: deltaX, y: deltaY, mouseX: x / scale, mouseY: y / scale,
                input: ScrollInput(unit: .lines, device: .wheel))))
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
        let value = Snapshot(session: sessionID, state: launch.mode == .counter ? counter.checkpoint : ["page": gallery.currentPage.rawValue],
            focused: focus.map { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String ?? "field.\($0.id)" },
            preedit: focus?.attachments["preedit"] as? String ?? "", controls: controls,
            width: size.x, height: size.y, scale: scale, typography: typography.statistics,
            vertices: list.vertices.count, indices: list.indices.count, frames: frames,
            mode: launch.mode.rawValue, page: launch.mode == .gallery ? gallery.currentPage.rawValue : nil,
            game: game?.snapshot(), editor: editorSnapshot, nodes: semanticNodes())
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
